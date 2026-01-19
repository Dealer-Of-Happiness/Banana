# AI Goodbye - Auto-Update Server Configuration

This directory contains the configuration for the Tauri auto-update system.

## How Auto-Updates Work

1. The desktop app checks `https://aigoodbye.ai/api/updates/{target}/{arch}/{version}` for new versions
2. If a new version is available, the user is prompted to update
3. The update is downloaded and installed automatically

## Setting Up Updates

### 1. Generate Update Keys

First, generate a signing key pair:

```bash
# Install tauri-cli if not already installed
cargo install tauri-cli

# Generate keys
cargo tauri signer generate -w ~/.tauri/aigoodbye.key
```

Save the public key and add it to `tauri.conf.json`:

```json
{
  "plugins": {
    "updater": {
      "pubkey": "YOUR_PUBLIC_KEY_HERE"
    }
  }
}
```

### 2. Update Endpoint

Create an API endpoint at `https://aigoodbye.ai/api/updates/{target}/{arch}/{current_version}` that returns:

```json
{
  "version": "1.0.1",
  "notes": "Bug fixes and improvements",
  "pub_date": "2024-01-15T12:00:00Z",
  "url": "https://aigoodbye.ai/downloads/AIGoodbye_1.0.1_x64-setup.nsis.zip",
  "signature": "SIGNATURE_HERE"
}
```

### 3. Signing Releases

When building a release, the artifacts are automatically signed if the private key is available:

```bash
export TAURI_SIGNING_PRIVATE_KEY="$(cat ~/.tauri/aigoodbye.key)"
npm run build
```

### 4. Hosting Updates

Upload the following to your server:

- **Windows**: `AIGoodbye_X.X.X_x64-setup.nsis.zip`
- **macOS (Intel)**: `AIGoodbye_X.X.X_x64.dmg.tar.gz`
- **macOS (Apple Silicon)**: `AIGoodbye_X.X.X_aarch64.dmg.tar.gz`
- **Linux**: `AIGoodbye_X.X.X_amd64.AppImage.tar.gz`

## Example Server Implementation (Node.js)

```javascript
// Example Express.js endpoint
app.get('/api/updates/:target/:arch/:version', (req, res) => {
  const { target, arch, version } = req.params;
  const latestVersion = '1.0.1';

  // Check if update is available
  if (version >= latestVersion) {
    return res.status(204).send(); // No update
  }

  // Return update info
  res.json({
    version: latestVersion,
    notes: 'Bug fixes and improvements',
    pub_date: '2024-01-15T12:00:00Z',
    url: `https://aigoodbye.ai/downloads/AIGoodbye_${latestVersion}_${arch}-setup.zip`,
    signature: 'SIGNATURE_FROM_BUILD'
  });
});
```

## File Structure on Server

```
/downloads/
├── AIGoodbye_1.0.0_x64-setup.nsis.zip
├── AIGoodbye_1.0.0_x64-setup.nsis.zip.sig
├── AIGoodbye_1.0.0_x64.dmg.tar.gz
├── AIGoodbye_1.0.0_x64.dmg.tar.gz.sig
├── AIGoodbye_1.0.0_aarch64.dmg.tar.gz
├── AIGoodbye_1.0.0_aarch64.dmg.tar.gz.sig
└── update.json
```

## Security Notes

- Keep your private signing key secure
- Never commit the private key to version control
- Use environment variables for CI/CD
- Always verify signatures before applying updates
