# GlobalProtect Toggle

Install in the expected location:

```bash
mkdir -p ~/scripts
cp gp-toggle.sh ~/scripts/gp-toggle.sh
chmod +x ~/scripts/gp-toggle.sh
```

## Usage
* `sudo ~/scripts/gp-toggle.sh off`     # fully stop, stays off across reboots
* `sudo ~/scripts/gp-toggle.sh on`      # restore it
* `~/scripts/gp-toggle.sh status`       # check state, no sudo

You can also run the script directly from this repo:

```bash
./gp-toggle.sh status
sudo ./gp-toggle.sh off
```
