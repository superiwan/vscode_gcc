# STM32 VSCode 模板

这个仓库提供一套面向 `STM32` 固件工程的 `VSCode` 工作区模板。重点不是再让你手工复制和手工改配置，而是用一条命令自动补齐项目。

适合的场景：

- 标准 `STM32CubeMX` 工程
- 已有 `CMakeLists.txt`、启动文件、链接脚本的 STM32 工程
- 想继续保留 `.ioc`，但不再依赖 `Keil`

## 一条命令

```powershell
powershell -ExecutionPolicy Bypass -File D:\vscode_gcc\tools\Initialize-Stm32Workspace.ps1 -ProjectRoot "<工程根目录>"
```

这条命令会自动完成这些事：

- 识别 `.ioc`、`CMakeLists.txt`、`startup_*.s`、`*.ld`
- 备份目标项目原有的 `.vscode` 和 `tools`
- 写入模板版 `.vscode` 和 `tools`
- 生成本地 [`.vscode/settings.json`](/D:/vscode_gcc/.vscode/settings.template.json) 对应的项目配置
- 自动修正明显不稳的项目名和 `.ioc` 文件名
- 检查环境
- 如果工程能编译，自动 `Configure + Build`

## 仓库里有什么

- [`.vscode/settings.template.json`](/D:/vscode_gcc/.vscode/settings.template.json)
  本地 `settings.json` 的模板。
- [`.vscode/tasks.json`](/D:/vscode_gcc/.vscode/tasks.json)
  常用任务。
- [`.vscode/launch.json`](/D:/vscode_gcc/.vscode/launch.json)
  调试入口。
- [`tools/Initialize-Stm32Workspace.ps1`](/D:/vscode_gcc/tools/Initialize-Stm32Workspace.ps1)
  一键初始化入口。
- [`tools/STM32.Common.ps1`](/D:/vscode_gcc/tools/STM32.Common.ps1)
  统一做路径处理和工具探测。
- [`tools/Invoke-Stm32Doctor.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32Doctor.ps1)
  检查环境。
- [`tools/Invoke-Stm32Build.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32Build.ps1)
  负责配置、编译、清理。
- [`tools/Invoke-Stm32Flash.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32Flash.ps1)
  负责烧录和整片擦除。
- [`tools/Invoke-Stm32CubeMXGenerate.ps1`](/D:/vscode_gcc/tools/Invoke-Stm32CubeMXGenerate.ps1)
  负责打开 CubeMX 或重新生成工程。
- [`tools/Invoke-StlinkGdbServer.ps1`](/D:/vscode_gcc/tools/Invoke-StlinkGdbServer.ps1)
  负责启动和停止外部 `ST-LINK gdbserver`。

## 安装要求

建议在 Windows 上准备好这些工具：

- `Visual Studio Code`
- `CMake`
- `Ninja`
- `Arm GNU Toolchain`
- `STM32CubeProgrammer`
- `ST-LINK_gdbserver`

带 `.ioc` 的项目还需要：

- `STM32CubeMX`

VSCode 扩展建议安装：

- `ms-vscode.cmake-tools`
- `ms-vscode.cpptools`
- `marus25.cortex-debug`

## 识别规则

- 有唯一 `.ioc`：优先按 `CubeMX` 工程处理
- 没有 `.ioc`，但有 `CMakeLists.txt + startup + ld`：按混合工程补齐
- 信号不够：不乱猜，只输出缺项

自动识别的重点信息：

- 项目名
- `.ioc` 文件路径
- 芯片型号
- 调试所需工具路径

## 初始化后的结果

目标项目里会出现这些内容：

- `.vscode/`
- `tools/`
- 本地 `.vscode/settings.json`
- `.stm32-init-backup/<时间戳>/`

其中本地 `settings.json` 和备份目录会被加入 `.gitignore`，默认不提交。

## 常用任务

- `STM32: Check Environment`
- `STM32: Generate From CubeMX`
- `STM32: Build`
- `STM32: Build and Flash`
- `STM32: Rebuild and Flash`
- `STM32: Flash`
- `STM32: Erase Chip`
- `STM32: Open CubeMX`

## 调试

调试入口已经在 [`.vscode/launch.json`](/D:/vscode_gcc/.vscode/launch.json) 里配好。

常用配置：

- `STM32: Debug active CMake target`
- `STM32: Debug via external GDB Server`
- `STM32: Attach active CMake target`

如果你的探针在直连模式下不稳定，优先用：

- `STM32: Debug via external GDB Server`

## 忽略规则

[`.gitignore`](/D:/vscode_gcc/.gitignore) 默认忽略这些本地产物：

- `build/`
- `.cache/`
- `.cmake/`
- `.omx/`
- `.vscode/settings.json`
- `.stm32-init-backup/`

## 参考

- [STM32 VS Code 官方页面](https://www.st.com/en/development-tools/stm32vscode.html)
- [STM32CubeIDE for Visual Studio Code 文档](https://dev.st.com/stm32cube-docs/stm32cubeide-vscode/latest/en/index.html)
- [STM32CubeProgrammer 官方页面](https://www.st.com/content/st_com/en/products/development-tools/software-development-tools/stm32-software-development-tools/stm32-programmers/stm32cubeprog.html)
- [STM32CubeMX 用户手册 UM1718](https://www.st.com/resource/en/user_manual/um1718-stm32cubemx-for-stm32-configuration-and-initialization-c-code-generation-stmicroelectronics.pdf)
