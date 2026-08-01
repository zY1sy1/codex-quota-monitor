# Skill 契约测试 CRLF 兼容修复实施计划

> **供智能代理执行：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，逐项实施本计划。所有步骤均使用复选框跟踪。

**目标：** 让 skill 策略契约测试在 LF 和 Windows CRLF 检出中都可靠通过，同时用确定性回归断言防止问题复发。

**架构：** 只修改 `tests/Unit/SkillContract.Tests.ps1`。测试先在内存中把 skill 文本转换为 CRLF，证明现有行尾正则会失败；实现仅让两条带 `$` 行尾锚点的策略规则接受可选的 `\r`，不改变插件、skill 内容或仓库换行策略。

**技术栈：** PowerShell 7、Pester 5.7.1、Git、Windows CRLF/LF 文本处理。

---

### 任务 1：建立确定性的 CRLF 回归测试

**文件：**
- 修改：`tests/Unit/SkillContract.Tests.ps1:133`
- 测试：`tests/Unit/SkillContract.Tests.ps1`

- [ ] **步骤 1：加入失败的 CRLF 回归断言**

在现有 `defines positive mutation, privacy, auth, preserve-data, and close-versus-exit rules` 测试之后加入：

```powershell
    It 'accepts policy lines with CRLF endings' {
        $crlfContent = $SkillContent -replace "(?<!`r)`n", "`r`n"

        Test-SkillPolicyContract -Content $crlfContent | Should -BeTrue
    }
```

- [ ] **步骤 2：运行单元测试并确认新增断言按预期失败**

运行：

```powershell
pwsh -NoLogo -NoProfile -File .\build\Test.ps1 -Suite Unit -CI
```

预期：命令退出码为 `1`；输出明确包含 `accepts policy lines with CRLF endings` 失败，并指向 `Test-SkillPolicyContract` 返回 `False`。在当前 D 盘 CRLF 检出中，原有正向策略契约断言也可能同时失败，这是同一根因。

- [ ] **步骤 3：确认暂存范围仍为空**

运行：

```powershell
git status --short
git diff -- tests/Unit/SkillContract.Tests.ps1
```

预期：仅 `tests/Unit/SkillContract.Tests.ps1` 出现未提交代码修改；`/.worktrees/` 已被 `.gitignore` 忽略且不得提交；`.superpowers/` 如存在则保持未跟踪且不得提交。

### 任务 2：实施最小的 CRLF 行尾兼容修复

**文件：**
- 修改：`tests/Unit/SkillContract.Tests.ps1:49-50`
- 测试：`tests/Unit/SkillContract.Tests.ps1`

- [ ] **步骤 1：让两条行尾锚定规则接受可选回车符**

把 `Test-SkillPolicyContract` 中对应的两条规则改为：

```powershell
            '(?m)^- Never print credentials, tokens, environment secrets, `auth\.json`, provider headers, raw App Server messages, raw JSON-RPC traffic, or full logs\.\r?$',
            '(?m)^- Closing the floating window \(`Close`\) hides it to the system tray\. Choosing `Exit` from the tray stops monitoring\.\r?$'
```

不要修改其他规则，也不要对 `$Content` 做全局换行归一化。

- [ ] **步骤 2：运行单元测试并确认回归转绿**

运行：

```powershell
pwsh -NoLogo -NoProfile -File .\build\Test.ps1 -Suite Unit -CI
```

预期：退出码为 `0`；`defines positive mutation, privacy, auth, preserve-data, and close-versus-exit rules` 与 `accepts policy lines with CRLF endings` 均通过，单元测试失败数为 `0`。

- [ ] **步骤 3：运行完整测试套件**

运行：

```powershell
pwsh -NoLogo -NoProfile -File .\build\Test.ps1 -Suite All -CI
```

预期：退出码为 `0`；`Tests Passed: 355, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0`。

- [ ] **步骤 4：检查差异并只提交测试修复**

运行：

```powershell
git diff --check
git status --short
git diff -- tests/Unit/SkillContract.Tests.ps1
git add -- tests/Unit/SkillContract.Tests.ps1
git diff --cached --check
git diff --cached --stat
git commit -m "test: accept CRLF in skill policy contract"
```

预期：暂存区只包含 `tests/Unit/SkillContract.Tests.ps1`；提交成功，设计文档提交保持不变；`/.worktrees/` 已被 `.gitignore` 忽略且不得提交；`.superpowers/` 如存在则保持未跟踪且不得提交。

### 任务 3：发布修复分支并核验远端

**文件：**
- 不新增或修改代码文件

- [ ] **步骤 1：推送修复分支**

运行：

```powershell
git push -u origin agent/fix-crlf-skill-contract
```

预期：远端创建 `agent/fix-crlf-skill-contract`，本地分支开始跟踪对应远端分支。

- [ ] **步骤 2：创建合并到 `main` 的 Pull Request**

使用 GitHub 连接器创建 PR，参数固定为：

```text
repository_full_name: zY1sy1/codex-quota-monitor
base: main
head: agent/fix-crlf-skill-contract
title: Fix CRLF handling in skill contract tests
draft: false
```

PR 正文说明：根因是 `$` 行尾锚点不接受 CRLF 中的回车符；修改只影响测试；验证结果为完整 355 项通过。

- [ ] **步骤 3：核验 PR 与远端提交**

运行：

```powershell
gh pr view agent/fix-crlf-skill-contract --repo zY1sy1/codex-quota-monitor --json number,state,isDraft,mergeable,baseRefName,headRefName,url
git ls-remote --heads origin main agent/fix-crlf-skill-contract
git status -sb
```

预期：PR 为打开、非草稿、目标 `main`、来源 `agent/fix-crlf-skill-contract`；远端存在两个分支；工作树无代码修改；`.worktrees/` 被忽略，`.superpowers/` 如存在则保持未跟踪。
