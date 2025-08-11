# 📓 JupyterLab Setup & Usage for CRC / Tetragon Notebooks

This guide explains how to install **JupyterLab** on macOS using **Homebrew** and run the included notebooks with both Python and CLI (CRC / OpenShift / Tetragon) commands.

---

# Dependency to have pythin installed
brew install python

---

# Install pipx (isolated Python app runner)
brew install pipx
pipx ensurepath

# Install JupyterLab
pipx install jupyterlab

---

# Launch JupyterLab
cd /path/to/project
jupyter lab          # Opens JupyterLab in your browser

