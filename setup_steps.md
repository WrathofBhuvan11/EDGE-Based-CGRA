### Install nix
 ```
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm --extra-conf "
extra-su>     extra-substituters = https://nix-cache.fossi-foundation.org
>     extra-trusted-public-keys = nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=
> "
```
### Run for librelane
` nix-shell --pure $HOME/librelane_dev/shell.nix `

Note- Librelane dev branch
