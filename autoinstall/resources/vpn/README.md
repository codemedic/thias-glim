# VPN Resources

Place OpenVPN client config files (`.ovpn`) here.

These files are **not tracked by git** — copy them onto the USB stick manually
after running `glim.sh`, or keep them in a secure location and copy as needed.

Files here are referenced by profile manifests and embedded into the CIDATA
`user-data` by `deploy-profile.sh` at deploy time.

Expected files (for the software-engineer profile):
- `corp-vpn-uk.ovpn`
- `corp-vpn-us.ovpn`
