# 代码格式规范

从当前 `mynpu-softpe` 仓库根目录运行：

```sh
make format-setup   # 首次安装固定版本工具到用户缓存
make format         # 应用格式
make format-check   # 只检查；有差异或工具报错时返回非零
```

默认 Python 为 `/usr/bin/python3.12`，可用 `make PYTHON=python3.12 ...` 指定。格式工具默认位于 `~/.cache/mynpu-format/bin`；可用 `FORMAT_TOOL_DIR` 指定其他目录。安装器适用于 Linux x86_64，下载官方发布包并核对固定的二进制 SHA-256；重复安装会复用已校验的工具。版本、下载地址及校验值见 [formatters.json](tools/formatters.json)，不把工具二进制放进仓库。

## 规则与范围

| 代码 | 工具与配置 | 规则 |
|---|---|---|
| SystemVerilog `.sv/.svh` | Verible，[.verible-format](.verible-format) | 2 空格缩进，续行 4 空格，目标行宽 100；端口连接对齐，声明和赋值左对齐；展开多条挤在同一行的语句 |
| Python `.py` | Ruff，[ruff.toml](ruff.toml) | 4 空格缩进，目标行宽 100，双引号，LF；只格式化，不自动改写或重排导入 |
| C `.h/.c` | clang-format，[.clang-format](.clang-format) | LLVM 风格，2 空格缩进，目标行宽 100，不重排 include |
| Shell `.sh` | shfmt，参数固定于统一入口 | Bash 语法，2 空格缩进，case 分支缩进，重定向留空格，管道续行统一 |
| 通用编辑行为 | [.editorconfig](.editorconfig) | UTF-8、LF、文件末尾换行；普通代码清除行尾空白，Makefile 使用 tab，Markdown 保留硬换行空格 |

自动格式化覆盖 `npu/` 和 `tools/` 下上述六类扩展名，包括当前 RTL、测试台、固件生成器、EDA/Python 脚本和 C 软件接口。统一入口为 [format_code.py](tools/format_code.py)，会先成功生成所有文件的格式结果，再开始写入；`--check` 不写入文件。

`external/`、PDK、`build/`、`reports/`、`mnist/artifacts/`、调试产物及其他生成目录不参与。Tcl、XDC、汇编和工程 XML 本轮没有自动重排工具，仅约定通用编辑行为。Verible 使用稳定的默认长表达式策略，不启用实验性长行自动折叠；长公式、字符串和注释可能超过目标行宽，检查以固定工具的实际输出为准。

工具规则依据：[Verible 官方说明](https://github.com/chipsalliance/verible/blob/master/verible/verilog/tools/formatter/README.md)、[Ruff 官方说明](https://docs.astral.sh/ruff/formatter/)。具体行为以仓库内固定版本和配置为准。

## 修改与验证约束

格式化不调整算子、位宽、状态机、FIFO 深度、寄存器地址或整数计算顺序。Python 格式结果写入前会比较 AST；Verible 启用输出收敛检查，解析失败不会作为成功跳过。格式化后再次执行 `make format-check` 应没有差异。

本轮同时修复了原验证脚本对源码排版的依赖：

- [sim_sources.py](npu/scripts/sim_sources.py) 生成 SRAM 宏 wrapper 时匹配完整实例，不再依赖固定空格和换行。
- RTL 性能探针通过 `NPU_GATE_SIM` 条件编译隔离；网表脚本不再按行删除 `dut.i_core` 表达式。单图测试台支持 `+samples=N`，默认仍为 10 个样本。
- 旧综合 manifest 的原始 SHA 检查仍保留。需要在格式化后的源码上复测旧网表时，显式提供冻结的格式化前目录：

```sh
/usr/bin/python3.12 npu/scripts/run_gate.py \
  --run ../eda-runs/20261103-cnn-cleanup/asic \
  --format-baseline ../eda-runs/20261103-code-format/before \
  --suite latency --tag NEW_GATE_TAG --max-cycles 20000
```

此模式逐文件核对冻结源码的原始 SHA，并以 Verible 比较当前 RTL 的 token；任何实际 token 改动都拒绝复用旧网表。结果记录旧、新源码 SHA 和等价验证。没有该选项时仍要求源码 SHA 完全一致。
