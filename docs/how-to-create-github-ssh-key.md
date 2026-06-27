# How to Create an SSH Key for GitHub Access

This guide walks you through creating and configuring an SSH key for secure GitHub authentication.

---

## Overview

SSH (Secure Shell) provides a secure way to authenticate with GitHub without repeatedly entering your username and password. This document covers:

- Generating a new SSH key pair
- Adding the public key to your GitHub account
- Configuring SSH to use the key
- Testing the connection
- Troubleshooting common issues

---

## Prerequisites

- **Operating System**: Linux, macOS, or Windows (with WSL/OpenSSH)
- **Terminal/Command Prompt** access
- **GitHub account** with repository access

---

## Step-by-Step Instructions

### Step 1: Check for Existing SSH Keys

First, check if you already have SSH keys on your system:

```bash
ls -al ~/.ssh
```

Look for files named `id_rsa` (RSA key) or `id_ed25519` (ED25519 key).

If you see keys, you can skip to **Step 4** (add public key to GitHub).

If no keys exist (or you want to create a new one), continue to **Step 2**.

---

### Step 2: Generate a New SSH Key

#### Option A: ED25519 (Recommended - Most Secure)

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

**Where:**
- `-t ed25519`: Use ED25519 algorithm (modern, secure)
- `-C "your_email@example.com"`: Add your email as comment (helps identify the key)

#### Option B: RSA (Compatible with older systems)

```bash
ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
```

**Where:**
- `-t rsa`: Use RSA algorithm
- `-b 4096`: Use 4096-bit key length

> **Note**: ED25519 is preferred over RSA for new keys. RSA is kept for compatibility.

---

### Step 3: Save the SSH Key

You'll be prompted to save the key location. Press **Enter** to accept the default path (`~/.ssh/id_ed25519`).

**Best practices:**
- Add a **passphrase** for enhanced security
- Store safely (don't share your passphrase)
- Your key passphrase should be at least 12 characters

> **Tip**: If you add a passphrase, you'll need SSH agent to avoid entering it for each connection.

---

### Step 4: Add Your Public Key to GitHub

Your public key will be at `~/.ssh/id_ed25519.pub` (or `id_rsa.pub` for RSA).

#### Method A: Copy to Clipboard

**macOS:**
```bash
cat ~/.ssh/id_ed25519.pub | pbcopy
```

**Linux:**
```bash
cat ~/.ssh/id_ed25519.pub | xclip -selection clipboard
```

**Windows:**
Copy the output manually from your terminal.

#### Method B: Use GitHub CLI

```bash
gh auth setup-git
```

This will guide you through authentication and key setup.

---

### Step 5: Add Key to GitHub Account

1. Log in to GitHub (https://github.com)
2. Click your profile picture (top-right)
3. Go to Settings
4. In left sidebar, click "SSH and GPG keys"
5. Click "New SSH key"
6. Add a title (e.g., "My Home Lab")
7. Paste the public key content (from clipboard)
8. Click "Add SSH key"
9. Confirm with your GitHub password if prompted

---

### Step 6: Test the Connection

```bash
ssh -T git@github.com
```

**Expected output if successful:**
```
Hi ChadEngel! You've successfully authenticated, but GitHub does not provide shell access.
```

If you see "Permission denied", the key may not be properly added to GitHub.

---

### Step 7: Configure SSH Agent

To avoid entering your passphrase repeatedly:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

Add to your shell profile for persistence:
```bash
echo 'eval "$(ssh-agent -s)"' >> ~/.bashrc
echo 'ssh-add ~/.ssh/id_ed25519' >> ~/.bashrc
source ~/.bashrc
```

---

### Step 8: Clone a Repository (Test)

```bash
git clone git@github.com:ChadEngel/ce-ai-home-lab.git
```

You should be able to clone without being prompted for a password.

---

## Security Best Practices

1. **Never share your private key** (id_ed25519, NOT id_ed25519.pub)
2. **Use a strong passphrase** to encrypt the private key
3. **Keep backups** of your private key (encrypted)
4. **Restrict permissions** on your SSH directory:
```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

---

## Troubleshooting

### "Permission denied (publickey)"

Check which key SSH is using:
```bash
ssh -vT git@github.com
```

### "Bad owner or permissions"

Fix permissions:
```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
```

### SSH Agent issues

Check the agent is running:
```bash
ps aux | grep ssh-agent
```

---

## Quick Reference Commands

```bash
# Check existing keys
ls -al ~/.ssh

# Check key fingerprint
ssh-keygen -lf ~/.ssh/id_ed25519.pub

# Test SSH connection
ssh -T git@github.com

# Add key to SSH agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Set proper permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

---

## Related Documentation

- [GitHub SSH Setup Guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
- [SSH Key Management Best Practices](https://security.stackexchange.com/questions/147/ssh-best-practices-for-key-management)

---

With SSH keys, you can securely interact with GitHub without exposing your password!
