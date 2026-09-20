 /goal Produce a verified, encrypted, locally saved handoff of the Claude Code sessions and explicitly approved repository context on this Windows machine, with instructions another person can
  use. Do not declare the goal achieved until the archive and checksum exist and archive verification passes.

  You are running on the EXPORTING machine. This data belongs to the person using this machine, not to the eventual recipient.

  First, inspect the installed Claude Code version and the actual local storage paths, including CLAUDE_CONFIG_DIR if set. Identify available session transcripts, subagent transcripts, tool
  results, prompt history, auto memory, plans, and project-level CLAUDE.md/AGENTS.md files. Do not assume every documented path exists. Inventory project paths and counts without printing chat
  contents or secrets.

  Before exporting, show the owner a concise scope list and ask them:
  1. Which projects and sessions may be shared?
  2. Should the handoff contain readable chat transcripts, raw session files, or both?
  3. Which repositories, if any, may be included as source files? A repository's conversation history does not itself grant permission to share its code.
  Do not proceed with any project or repository they have not approved.

  Create a lean Windows PowerShell export workflow. Keep outputs outside the source repositories and Claude configuration directory. Preserve approved raw session files and related subagent/
  tool-result files without changing the originals. Produce a readable per-project index with session IDs, dates, and source paths, plus a short context handoff describing approved repository
  locations, branches/commits, relevant instruction files, and how the recipient can use the materials. Distinguish facts extracted from files from your own summaries.

  If source repositories are approved, include only the approved repositories and agreed contents. Exclude credentials, .env files, private keys, tokens, dependency/build caches, and gitignored
  files by default. Do not include Git history or uncommitted changes without separate explicit approval. Do not copy global Claude settings, .claude.json, .credentials.json, authentication
  material, MCP credentials, or machine-specific permissions/hooks.

  Treat transcripts as sensitive even after excluding credential files: tool output may contain secrets. Scan the staged files for likely credentials without printing their values. Report
  affected file paths and stop for the owner's decision if anything sensitive is found; do not silently redact or ship it. Never upload data or invoke a cloud transfer service.

  After the owner approves the staged contents, package them in an encrypted archive using a locally available tool, with a password the owner enters privately. Do not put the password in a
  script, log, chat, or command-line argument. If you cannot achieve that securely with the installed tools, explain the limitation and ask the owner to perform the encryption in a local GUI.
  Create a SHA-256 checksum alongside the archive. Verify both archive integrity and the checksum. Remove temporary plaintext copies only after verification and only with the owner's approval.

  Because this Claude Code session may be writing to its own transcript, do not run the final live-data copy while Claude Code is open. Prepare the exact PowerShell command for the owner to run
  after closing Claude Code, Claude Desktop, and relevant IDE sessions. The script must produce a clear success/failure result.

  Include a README for the recipient explaining what was exported, what was excluded, how to verify and decrypt it, and how to read the sessions and context. Do not promise that copying raw
  session files will automatically make them resumable in another Claude Code installation unless you have tested that exact import seam on a separate installation. State any untested import
  behavior explicitly.

  At the end, provide only the exact archive and checksum paths, the approved project/session counts, verification output, exclusions, and any limitations. The owner will share the password
  separately.
