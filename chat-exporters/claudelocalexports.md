/goal Create a verified, encrypted, locally saved handoff containing my approved Claude Code sessions AND the local repositories/folders those sessions worked on. The recipient must be able
  to inspect the conversations and open usable copies of the approved projects. Do not declare success until the archive and checksum exist and archive integrity has been tested.

  You are on the EXPORTING machine. Do not upload any data.

  First, discover the actual Claude Code configuration and session locations, including CLAUDE_CONFIG_DIR if set. Inventory sessions, project paths, subagent transcripts, tool results, and
  project memory without printing conversation contents or secrets.

  Show me the discovered project paths. Ask me which repositories and non-Git folders I authorize you to share. Do not export a path merely because it appears in a chat. For each approved path,
  ask whether to include uncommitted and untracked work, Git history, submodules, and Git LFS content. Clearly identify anything that cannot be made portable.

  Build a minimal export workflow that includes:

  1. Approved raw Claude Code session files and their related subagent/tool-result files, preserving session IDs and directory relationships.
  2. A readable index mapping each session’s original working directory to its exported repository/folder.
  3. A portable copy of each approved repository’s working files, including explicitly approved uncommitted and untracked work. If Git history is approved, include a portable Git bundle rather
  than blindly copying `.git`; record the branch, commit, remote names, and any missing submodule or LFS content.
  4. Portable copies of approved non-Git folders.
  5. Relevant CLAUDE.md, AGENTS.md, project instructions, and auto-memory files needed to understand the work.
  6. A recipient README explaining how to restore the folders, map old paths to new paths, inspect sessions, and distinguish an archival transcript from a session that Claude Code can actually
  resume.

  Default exclusions: credentials, tokens, private keys, `.env` files, personal Claude authentication/settings, dependency caches, build output, and machine-specific hooks or permissions. Do
  not silently exclude an important project file: list every exclusion affecting an approved project. Gitignored files require my explicit approval before inclusion. Scan staged data—including
  transcripts, source files, Git history if included, and command output—for likely secrets without printing their values. Stop and ask me to review flagged paths before packaging. Do not
  silently redact files or assume that encryption makes sharing secrets acceptable.

  Keep staging and output outside the source projects and Claude configuration directory. Do not alter originals. Because this Claude Code session may still be writing a transcript, prepare the
  final copy command for me to run in normal PowerShell after closing Claude Code, Claude Desktop, and relevant IDE sessions; do not perform the live-data copy from this active session.

  After I approve the staged file list, create an encrypted archive using a locally available tool. I will enter the password privately; never put it in chat, source code, logs, or a command-
  line argument. If the installed tools cannot meet that condition, give me local GUI encryption steps instead. Create a SHA-256 checksum and test archive integrity.

  Verify that the archive contains every approved project/folder, the selected session files, the mapping manifest, and the recipient README. Report counts and sizes, not chat or secret
  contents. Do not claim that raw sessions will automatically appear in another Claude Code installation unless that exact import behavior has been tested there.

  Finish by giving me the exact archive and checksum paths, what was included/excluded, verification output, and any limitations. I will transfer the password separately.
