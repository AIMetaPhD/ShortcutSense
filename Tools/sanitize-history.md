# Sanitizing git history before publication

The working-tree sanitizer (`Tools/sanitize.py`) only cleans files as they are now.
It cannot remove strings from commits that are already written.

## What was done for this repository

The private staging repository's history was written before sanitization existed and
contained the owner's local usernames, the target Mac's Tailscale address and its
hostname. Because the repository was private with no forks, the history was replaced
rather than rewritten in place:

```bash
git checkout --orphan clean-main
git add -A
git commit -m "<one descriptive initial commit>"
git branch -D main
git branch -m clean-main main
git push <remote> main --force
```

A full backup of the original history was kept **outside** the repository.

## If you need to rewrite in place instead

`git filter-repo` is the supported tool (install with `pip install git-filter-repo`):

```bash
git filter-repo --replace-text replacements.txt
```

where `replacements.txt` contains one `literal==>replacement` pair per line. Do not
commit `replacements.txt`; it necessarily contains the sensitive strings.

## Before every public push

1. `python Tools/sanitize.py` — cleans the working tree.
2. `git grep -nIE '<each sensitive pattern>' $(git rev-list --all)` — must be empty
   except for the sanitizer's own pattern table.
3. `git log --all --format=%B | grep -nIE '<each pattern>'` — commit messages too.
4. Check that no key material was ever added:
   `git log --all -S'BEGIN OPENSSH PRIVATE KEY'`, `-S'gho_'`, `-S'<your token prefix>'`.
5. Confirm the target repository is private and has no forks before any force-push.
