# SELinux and MongoDB — Quick Reference

This document previously duplicated [006-selinux-reference.md](006-selinux-reference.md). All SELinux + MongoDB content is consolidated there.

**See [006-selinux-reference.md](006-selinux-reference.md)** for:

- SELinux in a bootc image (enforcing mode, build-time policy)
- MongoDB FTDC denials and the `mongodb-ftdc-local.te` module
- Build-time `semodule` compilation and installation
- First-boot `restorecon` via `ExecStartPre=`
- Case studies: all SELinux denials encountered and resolved
- The `bootc_testboot_local.te` supplemental module (tmpfiles + init_t rules)
- Verification checklist
