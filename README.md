# STM32 VSCode 工作区

这个工作区已经补好了 VSCode 侧的基本骨架，目标是让 `CubeMX + CMake + VSCode + ST-LINK` 这条线直接可用，不再依赖 `Keil` 做日常编译、下载和调试。

## 已加入的内容

- `/.vscode/tasks.json`
  直接提供环境检查、CubeMX 生成、配置、编译、烧录、整片擦除任务。
- `/.vscode/launch.json`
  直接提供 `Cortex-Debug + ST-LINK GDB server` 调试入口。
- `/.vscode/settings.json`
  集中放 STM32 工作区常用设置，芯片型号和工具路径都在这里改。
- `/tools/*.ps1`
  负责自动探测 `CMake`、`Ninja`、`GNU Tools for STM32`、`STM32CubeMX`、`STM32CubeProgrammer`、`ST-LINK_gdbserver`。

## 现在怎么用

1. 把你的 `.ioc` 文件和 `CubeMX` 生成出来的 `CMake` 工程放到这个工作区。
2. 打开 [`.vscode/settings.json`](/D:/vscode_gcc/.vscode/settings.json)，至少改这几项：
   - `stm32.device`
   - `stm32.iocFile`，如果工作区里不止一个 `.ioc`
   - `stm32.projectName`，如果你希望 `CubeMX` 重新生成时固定项目名
   - `stm32.cubeProgrammerPath`、`stm32.toolchainGdbPath`、`stm32.stlinkGdbServerPath`，如果这些工具不在 `PATH`
3. 在 VSCode 里运行任务：
   - `STM32: Check Environment`
   - `STM32: Generate From CubeMX`
   - `STM32: Build`
   - `STM32: Flash`
4. 在调试面板选择 `STM32: Debug active CMake target`。

## 这套骨架默认的前提

- 你仍然使用 `CubeMX` 做时钟、引脚、外设配置。
- `CubeMX` 的 `Toolchain/IDE` 已经设为 `CMake`。
- 下载器默认是 `ST-LINK`。
- 构建目录固定到 `build/Debug`。

## 这台机器当前查到的状态

- 已有：`STM32CubeMX 6.11.1`
- 已有：`CMake`
- 已有：`Ninja`
- 已有：`Arm GNU Toolchain`
- 已有：`STM32CubeProgrammer`，来自 ST 官方 bundles
- 已有：`ST-LINK_gdbserver`，来自 ST 官方 bundles
- 已有 VSCode 扩展：`CMake Tools`、`Cortex-Debug`、`C/C++`

现在缺的不是工具本身，而是你的实际 STM32 工程文件和芯片型号配置。

## 任务说明

- `STM32: Check Environment`
  检查这台机器上有没有关键工具。
- `STM32: Generate From CubeMX`
  用 `CubeMX` 的命令行重新生成 `CMake` 工程。
- `STM32: Build`
  用 `CMake + Ninja` 编译当前工程。
- `STM32: Flash`
  自动从 `build/Debug` 里找最新的 `elf/hex/bin` 并下载。
- `STM32: Erase Chip`
  直接整片擦除。
- `STM32: Open CubeMX`
  直接打开 `.ioc` 对应的 CubeMX 图形界面。

## 调试入口

[`.vscode/launch.json`](/D:/vscode_gcc/.vscode/launch.json) 现在已经接好：

- `servertype = stlink`
- `executable = 当前 CMake 活动目标`
- `runToEntryPoint = main`

要真正启动调试，至少还需要：

- 正确的 `stm32.device`
- `arm-none-eabi-gdb`
- `ST-LINK_gdbserver`
- 可被 `CMake Tools` 识别到的活动目标

## 参考

- [STM32 VS Code 官方页面](https://www.st.com/en/development-tools/stm32vscode.html)
- [STM32CubeIDE for Visual Studio Code 文档](https://dev.st.com/stm32cube-docs/stm32cubeide-vscode/latest/en/index.html)
- [STM32CubeProgrammer 官方页面](https://www.st.com/content/st_com/en/products/development-tools/software-development-tools/stm32-software-development-tools/stm32-programmers/stm32cubeprog.html)
- [STM32CubeMX 用户手册 UM1718](https://www.st.com/resource/en/user_manual/um1718-stm32cubemx-for-stm32-configuration-and-initialization-c-code-generation-stmicroelectronics.pdf)
