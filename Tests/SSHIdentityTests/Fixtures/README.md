# Test-only keys

Generated with `ssh-keygen` solely for `OpenSSHKeyImporterTests`. They protect
nothing and must never be authorized on a real server.

| File | Command options |
|---|---|
| `plain` | `-t ed25519 -N '' -C plain@fixture` |
| `aes256` | `-t ed25519 -N 'correct horse' -Z aes256-ctr` (ssh-keygen's default 16 rounds) |
| `aes128-ctr`, `aes256-cbc`, `aes128-gcm`, `aes256-gcm`, `chacha20` | `plain` re-encrypted: `ssh-keygen -p -P '' -N 'correct horse' -a 2 -Z <cipher>` (`aes128-gcm@openssh.com`, `aes256-gcm@openssh.com`, `chacha20-poly1305@openssh.com`; ChaCha20 must be refused) |
| `rsa` | unsupported algorithm |
| `ecdsa-pem` | SEC 1 P-256 key with explicit curve parameters (refused); `.pub` from `ssh-keygen -y` |
| `ecdsa-pem-named` | `openssl ecparam -name prime256v1 -genkey -noout`; `.pub` from `ssh-keygen -y` |
| `ecdsa256`, `ecdsa384`, `ecdsa521` | `-t ecdsa -b <bits> -N '' -C ecdsa<bits>@fixture` |
| `ecdsa256-aes` | `-t ecdsa -b 256 -N 'correct horse' -a 2` |
| `plain-cert.pub` | a user certificate for `plain.pub` |
