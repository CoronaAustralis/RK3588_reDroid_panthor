# Fork 后构建修复版镜像

这条流程编译 Android ARM64 和 ARM32 Mesa/libdrm，再覆盖到上游预编译 reDroid 镜像；不编译 AOSP。

## 构建顺序

1. 提交并推送本次改动，在 Fork 的 Actions 页面启用工作流。
2. 运行 `android-mesa-panthor-build`。手动运行选择 `route=stub`（默认），
   Gallium/Vulkan 都保持 `panfrost`。`full` 需要完整 AOSP 头文件，当前不推荐。
   推送 `scripts/**` 等文件到 `main` 也会启动这项构建，不必重复手动运行。
3. 等待构建、校验、Release 发布全部成功，记录本仓库新生成的
   `android-mesa-panthor-<run>-<attempt>` 标签。
4. 手动运行 `redroid-rk3588-panthor-image`，在 `mesa_release_tag` 中填入该标签。
   `latest` 只在当前 Fork 的 Releases 中选择，绝不会回退到原作者仓库。
   必须使用这次新构建的双 ABI 产物；缺少 `prebuilts/arm` 或任一 GBM 后端会直接报错。
5. 构建成功后，从当前 Fork 的 GHCR 或 `redroid-image-<run>-<attempt>` Release 获取镜像。
   镜像失败时不发布 Release，诊断日志仍在 Actions Artifacts。

镜像组装取消了 push 自动触发，避免与 Mesa 构建并发，错误地使用上一次的产物。
权限已在工作流声明：Mesa 需要 `contents: write`，镜像还需要 `packages: write`；
如组织策略禁用这些权限，需要在对应仓库/组织设置中放行。私有 GHCR 包拉取需要登录。

## 修复内容

- 从同一次 Mesa 安装产物打包 `lib64/gbm/dri_gbm.so`，注入 `/vendor/lib64/gbm/`。
- 保留 `/vendor/lib64/dri/libgallium_dri.so`，添加相对链接
  `/vendor/lib64/libgallium_dri.so -> dri/libgallium_dri.so`，供 EGL/GBM 的裸名称依赖搜索。
- GBM 库 SONAME 改为 `libgbm.so.1` 时，同时更新所有注入 ELF 对原 SONAME 的依赖。
- 静态检查必须包含 GBM 后端的 AArch64 架构、动态导出 `gbmint_get_backend`、
  EGL/GBM 的 Mesa 系依赖路径。不能把子目录里存在同名文件当成链接器一定能找到。
- `tests/test-image-layout.sh` 使用小型 ARM64 ELF 测试真实的 SONAME/DT_NEEDED 改写，
  并覆盖缺后端、错误后端、旧依赖名、缺 Gallium 搜索入口等回归情况。

## 上板验证

在确认 `/dev/dri/renderD128` 绑定 Panthor 后，用新的镜像标签创建测试容器：

```bash
docker run -itd --name redroid-test --privileged --device /dev/dri/renderD128 \
  -p 5555:5555 YOUR_IMAGE \
  androidboot.redroid_gpu_mode=host \
  androidboot.redroid_gpu_node=/dev/dri/renderD128
docker exec redroid-test getprop sys.boot_completed
docker exec redroid-test dumpsys SurfaceFlinger | grep -iE 'GLES|Mali|Panfrost'
docker exec redroid-test logcat -b crash -d
```

将 `YOUR_IMAGE` 换成此次发布的镜像，并确保容器名称和宿主 5555 端口未被占用。
这个示例不挂载 `/data`，适用于可以丢弃数据的启动测试。

静态检查通过不等于 Android 已启动或硬件加速正常。必须确认 `sys.boot_completed=1`、
SurfaceFlinger 使用目标 GPU 且没有反复崩溃。宿主还需要 Binder、Netfilter/iptables
扩展和 dummy 等支持；此前的 `mark`、`CONNMARK`、`TCPMSS`、`dummy0` 错误属于另外的宿主兼容性问题。

## ARM32 支持（32 位 OMX / 应用）

一次 Mesa workflow 构建两套相同版本的 Panfrost、PanVK、EGL/GLES、GBM 后端、libdrm、NDK libc++。
ARM64 安装到 `/vendor/lib64`，ARM32 安装到 `/vendor/lib`。源码与宿主 CLC 工具只构建/获取一次，
两种 ABI 使用独立 sysroot、Mesa/libdrm 构建目录和安装目录，不需要编译整个 Android。
通用 cross-file 模板根据 TARGET_ARCH 渲染；ARM32 使用 NDK `armv7a-linux-androideabi33`。
单独调试一种 ABI 可执行 `TARGET_ARCH=arm bash scripts/build-all.sh`；双 ABI 使用
`bash scripts/build-dual-abi.sh`。

镜像工作流默认同时校验 ELF32/ARM 与 ELF64/AArch64，覆盖 NDK libc++，并用两种真实 ELF
夹具验证 SONAME 改写、依赖搜索、错误 ABI 拒绝和 overlay 合并。Linux ARM64 上运行：
`bash tests/test-dual-abi.sh`（需要 gcc、gcc-arm-linux-gnueabihf、binutils、patchelf）。
这类夹具只验证打包逻辑，不能代替 NDK 完整编译或板上运行。

重建镜像后先用 `scrcpy -s 192.168.5.70:5555 --no-audio` 验证画面持续更新，再检查日志是否仍有
`GRALLOC-GBM: failed to create gbm device`。原镜像缺 Opus 编码器是另一问题；可使用 AAC 或禁用音频。
Panthor 图形加速不代表已启用 Rockchip VPU 硬件视频编码，也不保证任意 32 位应用都能运行。
