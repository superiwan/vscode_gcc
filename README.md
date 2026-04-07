# STM32 VSCode 模板

这个仓库提供一套可直接复用的 VSCode 工作区模板，用来完成 STM32 工程的编译、烧录和调试。

适合的场景：

- 已经使用 `STM32CubeMX`
- 想继续保留 `.ioc` 图形配置
- 想在 `VSCode` 里完成开发，不再依赖 `Keil`

## 仓库里有什么

- [`.vscode/settings.json`](/D:/vscode_gcc/.vscode/settings.json)
  工作区参数，芯片型号、`.ioc` 路径、工具路径都在这里改。
- [`.vscode/tasks.json`](/D:/vscode_gcc/.vscode/tasks.json)
  已经配好的常用任务。
- [`.vscode/launch.json`](/D:/vscode_gcc/.vscode/launch.json)
  已经配好的调试入口。
- [`tools/STM32.Common.ps1`](/D:/vscode_gcc/tools/STM32.Common.ps1)
  统一做工具探测。
- [`tools/Invoke-Stm32Doctor.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32Doctor.ps1)
  检查环境。
- [`tools/Invoke-Stm32Build.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32Build.ps1)
  负责配置、编译、清理。
- [`tools/Invoke-Stm32Flash.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32Flash.ps1)
  负责烧录和整片擦除。
- [`tools/Invoke-Stm32CubeMXGenerate.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32CubeMXGenerate.ps1)
  负责打开 CubeMX 或用命令行重新生成工程。

## 安装要求

建议在 Windows 上准备好这些工具：

- `Visual Studio Code`
- `STM32CubeMX`
- `CMake`
- `Ninja`
- `Arm GNU Toolchain`
- `STM32CubeProgrammer`
- `ST-LINK_gdbserver`

VSCode 扩展建议安装：

- `ms-vscode.cmake-tools`
- `ms-vscode.cpptools`
- `marus25.cortex-debug`

如果你已经安装了 ST 官方扩展包，也可以一起使用，但这个模板本身不依赖 ST 的项目接管功能。

## 使用方法

1. 把这个仓库里的 `.vscode` 和 `tools` 放到你的 STM32 工程根目录。
2. 打开 [`.vscode/settings.json`](/D:/vscode_gcc/.vscode/settings.json)，至少修改下面这些项：
   - `stm32.projectRoot`
   - `stm32.iocFile`
   - `stm32.projectName`
   - `stm32.device`
   - `stm32.cubeProgrammerPath`
   - `stm32.toolchainGdbPath`
   - `stm32.stlinkGdbServerPath`
3. 如果你的工程还没有 `CMake` 工程文件，在 CubeMX 里把 `Toolchain/IDE` 设为 `CMake`。
4. 在 VSCode 里运行任务。

## 常用任务

- `STM32: Check Environment`
  检查当前机器上有没有关键工具。
- `STM32: Generate From CubeMX`
  用命令行方式让 CubeMX 重新生成工程。
- `STM32: Build`
  编译工程。
- `STM32: Build and Flash`
  编译后直接烧录。
- `STM32: Rebuild and Flash`
  先清理，再重新编译和烧录。
- `STM32: Quick Start`
  先检查环境，再编译和烧录。
- `STM32: Flash`
  直接烧录现有产物。
- `STM32: Erase Chip`
  整片擦除。
- `STM32: Open CubeMX`
  直接打开 `.ioc`。

## 调试

调试入口已经在 [`.vscode/launch.json`](/D:/vscode_gcc/.vscode/launch.json) 里配好。

常用配置：

- `STM32: Debug active CMake target`
- `STM32: Attach active CMake target`

## 忽略规则

[`.gitignore`](/D:/vscode_gcc/.gitignore) 已经排除了常见构建产物和本地状态文件。

重点包括：

- `build/`
- `.cache/`
- `.cmake/`
- `.omx/`

其中 `.omx/` 是本地运行状态和日志目录，不应该提交到仓库。

## 建议做法

- 把这个仓库当成模板使用，不要把本机生成的运行状态一起提交。
- 如果你的项目已经有自己的 `CMakeLists.txt`，只复用 `.vscode` 和 `tools` 即可。
- 如果你改了 `.ioc`，先重新生成，再编译和烧录。

## 参考

- [STM32 VS Code 官方页面](https://www.st.com/en/development-tools/stm32vscode.html)
- [STM32CubeIDE for Visual Studio Code 文档](https://dev.st.com/stm32cube-docs/stm32cubeide-vscode/latest/en/index.html)
- [STM32CubeProgrammer 官方页面](https://www.st.com/content/st_com/en/products/development-tools/software-development-tools/stm32-software-development-tools/stm32-programmers/stm32cubeprog.html)
- [STM32CubeMX 用户手册 UM1718](https://www.st.com/resource/en/user_manual/um1718-stm32cubemx-for-stm32-configuration-and-initialization-c-code-generation-stmicroelectronics.pdf)
