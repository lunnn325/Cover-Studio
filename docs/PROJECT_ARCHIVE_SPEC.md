# 工程数据格式、备份包与跨设备迁移

## 1. 逻辑数据模型

```text
Song(id, title, artist, cover, groupingHints)
  ├─ Arrangement(id, sourceAsset, optionalOriginalVocal, backingStem, semitoneShift, lyricSource)
  └─ Project(id, arrangementID, schemaVersion, editGraphID, originDevice, revision/branch)
       ├─ Take(id, kind: audio|video, sourceAssets[], recordingSegments[], timestamps, routeInfo)
       ├─ PracticeRecording(id, assets[], optionalPromotedTakeID)
       ├─ EditGraph(selectedTakeID, gains, eq, reverb, denoise, optionalPitchCorrect,
       │          syncOffset, stitchCuts, videoCrop, subtitles, subtitleStyle, mirrors)
       └─ Exports(id, variant, format, status, optionalAsset)
```

建议 stable UUID、不随文件改名变化；文件路径全部是**相对工程根目录**，别保留某台 iPhone 的沙盒绝对路径。大型内容用 immutable media assets，编辑图保存引用；copy-on-write 分支尽量不重复拷贝视频。

## 2. 建议自包含 archive

扩展名暂定 `.coverproject`（本质可采用 ZIP+JSON 等能校验的开放结构，Codex 可调整并说明）：

```text
coverproject/
  manifest.json          # schemaVersion, appVersion, projectId, archiveId, createdAt
  metadata/song.json
  metadata/arrangements.json
  metadata/takes.json
  metadata/editGraph.json
  metadata/lyrics.json
  media/audio/<uuid>.*
  media/video/<uuid>.*
  media/images/<uuid>.*
  integrity/assets.sha256.json # relativePath, bytes, sha256, contentRole, usedBy
```

必须显式定义：schemaVersion / minReaderVersion / featureFlags / originalProjectID / archivedRevision / sourceDeviceID / hash algorithm / manifest hash。媒体/音轨采样率、channels、时长、起始时间戳的有理数形式必须足够精确，避免另一设备重新解释时间轴失真。

## 3. 三种备份

- **完整 Full**：全部 Arrangement、Take、练习素材（除用户明确删除项）、编辑和导出设置、所需原始媒体。是否包含已导出 MP4 可在自定义项中显示；完整工程可重新生成成品时可默认省去已导出成品，但要标明，避免“完整”语义误导。若用户理解完整备份应包括所有导出成品，则使用明显勾选项。
- **精简 Slim**：保留当前选中的 Take、所有被当前编辑引用的旧片段、适用的伴奏、歌词、必要封面/照片、编辑参数，允许排除不被引用的旧 Take。不得因删除旧 Take 而破坏拼接引用。
- **自定义 Custom**：允许用户按 Take/输出选择，但依赖闭包由系统强制添加；显示“因被引用不能移除”的解释。所有模式均必须通过 restore preflight。

原则：**任何备份模式都不能生成一个看似成功却缺依赖的不可恢复工程。**

## 4. 归档与存储状态

- `ACTIVE_LOCAL`：完整本地工程和源文件。
- `ARCHIVE_PREPARED`：本地归档包已创建且内容校验通过。
- `EXPORTED_TO_PROVIDER`：系统文件提供者接收/导出流程完成；不声明 Google Drive 远端已传完。
- `RESTORE_VERIFIED`：从外部选中的工程副本可重新导入、素材/哈希/依赖完整；仍不可证明远端永远保留。
- `ARCHIVED_INDEX_ONLY`：用户主动释放本地素材，只保留歌名、封面/缩略图、归档位置说明、最后验证状态与日期。

需要展示状态描述，不要用单个绿色“已备份”混淆本地归档成功和远端上传。

## 5. 恢复与冲突

1. 文件选择器选定 archive → 复制至安全临时区/受控读取 → 限制压缩解包大小/路径 → schema 兼容性验证 → SHA-256 校验 → 依赖关系验证。
2. 若已有相同 projectID+相同 revision，提示是否重复导入；如果存在修改分支/不同 revision，**先创建安全副本**后才能替换，可选“保留两份”。
3. 空间不足以建立副本时不得覆盖；应告知清理空间或只导入为独立工程（若空间允许）。
4. 导入和索引提交尽量原子性/事务性，故障后不能留下工程看似完整但数据半导入的状态。
5. 历史 schema 通过可测试迁移器支持或提供清晰“新版本工程不兼容”错误；不能静默丢弃未知字段影响现有编辑。

## 6. 「释放本地空间」规则

- 显示哪些源文件将被删除、预计释放空间、当前备份状态、Google Drive 上传未必完成的警告。
- 建议优先引导“从外部重新选中 archive 验证”；但用户此前明确最终可自行判断是否删除。没有验证时给强警告并再次确认，而不是假称安全。
- 不删除其他工程共享且仍被引用的媒体；不删除最近一次成功备份记录/索引。删除后清晰标记“已归档，本地源素材已移除”。
- 不自动后台删除任何原始 Take，缓存可单独提示清理。

## 7. 减少磁盘峰值占用

归档采用流式复制/压缩、增量哈希、单素材去重（相同哈希多引用）；事先估算所需临时空间。若空间不足优先让用户改目标/释放可重建缓存，不静默删除原始媒体，也不承诺没有足够空间仍一定能成功导出完整包。
