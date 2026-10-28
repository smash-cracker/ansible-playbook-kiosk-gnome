  # ── ONCE on the laptop (rebuild only if ISO/packages change) ──────────────
  cd /home/denny/Office/ansible-playbook-kiosk-gnome
  ./scripts/build_offline_bundle.py --baseline ./baseline-22.04.5.txt --output ~/offline-packages-delta
  cp -a ~/offline-packages-delta /media/$USER/DEBS/

 DO THIS 

  # ── PER VOIP DEVICE ─────────────────────────────────────────────────────────────
  bash /media/$USER/DEBS/offline-packages-delta/kiosk-firstboot.sh

  # 2. on the laptop: add the IP to hosts.ini, then
  ./scripts/deploy.sh --host <TARGET_IP> -vv
