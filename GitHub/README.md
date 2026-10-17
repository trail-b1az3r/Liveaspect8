# GitHub/ (visible copy of .github/)

GitHub only runs workflows from a folder named exactly `.github/workflows/`.
A folder called `GitHub/` is ignored by Actions, so this one is a **visible mirror** for
phones/file managers that hide dot-folders. The real one is `.github/workflows/build.yml`.

If `.github/` is missing in your repo (e.g. an uploader dropped it):

1. Repo on github.com → **Add file → Create new file**
2. In the name box type `.github/workflows/build.yml`
3. Paste the contents of `GitHub/workflows/build.yml` → **Commit**

Keep both copies identical if you edit the workflow.
