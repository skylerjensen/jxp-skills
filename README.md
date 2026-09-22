# jxp-skills

> JXP 个人 AI Skill 集合，供 DeepSeek Harness（DSH）加载。
> 单一入口：clone 本仓库 + 跑一次软链脚本，即可让所有 skill 生效。

## Skill 清单

| Skill | 用途 | 形态 |
| --- | --- | --- |
| [`jxp-wsl-network`](skills/jxp-wsl-network/) | WSL 网络/代理/镜像分流与排错：autoProxy 陷阱、国内外源选择、pip/npm/git/HF 加速、`wsl --update` 403 处置 | 目录 |
| [`jxp-video-to-text`](skills/jxp-video-to-text/) | 课程视频定向转写：抽音轨、ASR、术语纠错、骨架提取与保真转录 | **submodule**（独立仓库） |

> 形态约定：需要单独分享/独立版本化的 skill 用 **submodule** 指向自己的仓库；
> 轻量或尚未独立的 skill 直接放目录。二者对 DSH 加载无差别。

## 安装（接入 DSH）

```bash
# 1) 克隆（含 submodule）
git clone --recurse-submodules git@github.com:skylerjensen/jxp-skills.git ~/repos/jxp-skills

# 若已 clone 但没带 submodule
cd ~/repos/jxp-skills && git submodule update --init --recursive

# 2) 软链到 DSH 的 skill 加载目录
mkdir -p ~/.dsh/skills
for d in ~/repos/jxp-skills/skills/*/; do
  name="$(basename "$d")"
  ln -sfn "$(cd "$d" && pwd)" "$HOME/.dsh/skills/$name"
  echo "linked: $name"
done

# 3) 校验
ls -l ~/.dsh/skills/
```

DSH 会在下次会话加载这些 skill（`SKILL.md` 的 frontmatter `name` / `description` 决定何时触发）。

## 更新

```bash
cd ~/repos/jxp-skills
git pull
git submodule update --init --recursive    # 同步各 skill 的最新提交
```

软链指向目录本身，**更新内容后无需重新软链**（新会话生效）。

## 新增一个 skill

**A. 独立仓库（推荐用于可复用、要分享的）**

```bash
# 1) 在 GitHub 建空仓库 <skill-name>
# 2) 加入本仓库
cd ~/repos/jxp-skills
git submodule add git@github.com:skylerjensen/<skill-name>.git skills/<skill-name>
# 3) 补软链
ln -sfn "$(cd skills/<skill-name> && pwd)" ~/.dsh/skills/<skill-name>
# 4) 提交并推送
git add .gitmodules skills/<skill-name> && git commit -m "feat: add <skill-name>" && git push
```

**B. 直接放目录（轻量）**

```bash
mkdir -p ~/repos/jxp-skills/skills/<skill-name>
# 写入 SKILL.md（需 frontmatter: name + description）
ln -sfn "$(cd ~/repos/jxp-skills/skills/<skill-name> && pwd)" ~/.dsh/skills/<skill-name>
cd ~/repos/jxp-skills && git add skills/<skill-name> && git commit -m "feat: add <skill-name>" && git push
```

若日后想转为独立仓库，用 `git submodule add` 后删除目录内容即可。

## Skill 编写约定

- 每个 skill 一个目录，入口固定为 `SKILL.md`
- frontmatter 必填：
  ```yaml
  ---
  name: <kebab-case，与目录名一致>
  description: <一句话说明用途 + 何时触发；这是 DSH 决定是否加载的依据，要写清触发场景>
  ---
  ```
- 正文建议结构：何时使用 → 核心结论 → 可执行命令 → 已知坑 → 配套脚本
- 脚本放 `scripts/`，参考资料放 `references/`
- 中文书写；命令与路径保持可直接复制执行

## 注意

- 本仓库放在 `~/repos/`，**不要**放在笔记仓库内部（避免嵌套 git 与同步混乱）
- 大体积资产（模型权重、音视频）**不进仓库**，只记录获取方式与落点
