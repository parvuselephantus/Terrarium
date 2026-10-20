# AI Cage 0.3.0

Isolated Linux (Debian 13) virtual machines for AI agents on Windows. The AI gets full admin
rights inside its VM, the internet and one shared folder. It can't see the rest of your files,
your home, office or cowork network, or other VMs.

## You need

- Windows 10 or 11 **Pro, Enterprise or Education** (Home has no Hyper-V)
- Administrator rights, about 10 GB free disk, 8 GB RAM or more

## Start

1. Unzip the folder anywhere, e.g. `C:\Tools\AI-Cage`.
2. Double-click **AiCage.cmd** and allow Administrator rights.
3. The top of the window checks your laptop. If it shows **Fix problems**, click it (for example
   to turn on Hyper-V; Windows then needs a restart).
4. Click **+ New VM**, pick a name and a shared folder, click **Create VM**. It takes 2–3
   minutes (the first time it downloads Debian, about 420 MB).
5. **Terminal** opens a command line in the VM. The small arrow next to it picks the program: the
   Windows terminal or PuTTY (if installed). The VM sees the shared folder as `~/shared`.
6. Optional: tick **Docker**, **Claude Code** or **Codex** under *Install* when creating the VM.
   **Settings** changes memory, network and the shared folder of an existing VM.

Every new VM is checked automatically. If it can reach something it must not, AI Cage repairs
the protection; if that does not help, it disconnects the VM's network and tells you
(**quarantined**). **Test and secure** runs the check again at any time.

## Good to know

- Put nothing in the shared folder that the AI must not see. The AI is root in its VM.
- The default login is user `ai`, password `ai` (for `sudo`). The Terminal button needs no
  password, in the Windows terminal and in PuTTY: it logs in with a key.
- Each VM is stored either in your user folder (`C:\Users\<you>\.aicage`, the default) or in this
  program folder - you choose under *Stored in* when creating it. AI Cage finds VMs in both.
  The logs, the Debian image and the settings are always in `.aicage`. If something fails, the
  log in `.aicage\logs\` says what happened.
- If Windows blocks the files after downloading: right-click the zip, **Properties**, tick
  **Unblock**, then unzip again.
- To remove everything: delete the VMs with **Remove**, then run `AiCage.cmd console` and
  `Uninstall-AiCage`, then delete this folder and `.aicage`.
