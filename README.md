# My Cover Studio — Codex 可执行设计交付包

本文件夹是 **My Cover Studio V1**（原生 iPhone/iPad 翻唱工作室）的完整设计输入。来源为用户 14 轮 Grill Me 共 96 项选择。**当前没有任何 App 代码，也未运行任何 GitHub Actions 构建。**

## 给 Codex

请从 `CODEX_START_HERE.md` 开始读，再遵守 `AGENTS.md` 和 `docs/*.md`。

该用户希望先把产品完整设计，再集中让 Codex 开发，避免小功能每次都触发 GitHub 测试。已批准 Codex 对专业实现细节采取更好的方案，但不得擅改核心需求与数据保护边界。所有更改记录于 `docs/IMPLEMENTATION_ADR.md`。

## 可引用给 Codex 的起始提示词

> 请先完整阅读 CODEX_START_HERE.md、AGENTS.md 和 docs/ 下的全部规格文件。它们是已经过 14 轮 Grill Me 决定的 My Cover Studio V1 产品输入。请检查当前仓库（若为空则创建原生 iOS/iPadOS App），先统一工程架构、模型与页面，再集中实现核心 P0 和条件性 P1 功能。技术选型可以做更好的决定，但任何改动须符合 DECISIONS.md，并在 IMPLEMENTATION_ADR.md 记录。避免每次小修改就触发 GitHub macOS IPA 构建，只进行必要的轻量构建、少量实机冒烟测试。不要把未验证的 AirPods/AI/修音/备份能力称为已完成。请报告真实实现进度、阻断和用户需要提供的签名材料。
