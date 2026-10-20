# Terrarium - the AI cage

Isolated Linux (Debian 13) virtual machines for AI agents on Windows. The AI gets full admin
rights inside its VM, the internet and one shared folder. It can't see the rest of your files,
your home, office or cowork network, or other VMs.

Version 0.4.0. Formerly called *AI Cage*: VMs made by AI Cage keep working, and its internal
names (the `.aicage` folder, the `AICage` virtual switch, the `*-Aic*` commands) stay.

## You need

- Windows 10 or 11 **Pro, Enterprise or Education** (Home has no Hyper-V)
- Administrator rights, about 10 GB free disk, 8 GB RAM or more

## Start

1. Unzip the folder anywhere, e.g. `C:\Tools\Terrarium`.
2. Double-click **Terrarium.cmd** and allow Administrator rights.
3. The top of the window checks your laptop. If it shows **Fix problems**, click it (for example
   to turn on Hyper-V; Windows then needs a restart).
4. Click **+ New VM**, pick a name and a shared folder, click **Create VM**. It takes 2–3
   minutes (the first time it downloads Debian, about 420 MB).
5. **Terminal** opens a command line in the VM. The small arrow next to it picks the program: the
   Windows terminal or PuTTY (if installed). The VM sees the shared folder as `~/shared`.
6. Optional, under *Advanced*: install **Docker**, **Claude Code**, **Codex** or a **Desktop**,
   and choose where the VM is stored. **Settings** changes all of this for an existing VM too.

Every new VM is checked automatically. If it can reach something it must not, Terrarium repairs
the protection; if that does not help, it disconnects the VM's network and tells you
(**quarantined**). **Test and secure** runs the check again at any time.

## Desktop

*Desktop (XFCE)* installs a light graphical desktop with Firefox (about 1 GB). The **Desktop**
button opens it in Windows' Remote Desktop; log in with the Linux user and password. Remote
Desktop shares nothing of your laptop with the VM - not even the clipboard, which often holds
passwords. To allow copy and paste, set `redirectclipboard:i:1` in the VM's `.rdp` file (next to
its disk).

## Ports

*Ports to this laptop* (e.g. `8080, 5432, 3000:80`) makes services in the VM - say a Docker
container published on port 8080 - reachable from apps on your laptop as `localhost:8080`.
`3000:80` means laptop port 3000 to VM port 80. Only your laptop sees them, not your network.
TCP only. Without any forward, the laptop can also open `http://<VM address>:<port>` directly.
The VM still cannot reach anything on your laptop.

## When a VM does not answer

If the Terminal, PuTTY and the VM's screen stop reacting, the **Health** column usually shows
*not responding*. **Diagnose** looks at what Hyper-V sees (heartbeat, memory), Hyper-V's own
event log for the VM and - once SSH works - the VM's system log of this and the previous boot.
For a stuck VM it offers a restart; Diagnose afterwards explains the stuck boot.

The most common cause is memory: Hyper-V's Dynamic Memory gives an idle VM back to its minimum
and a busy VM then freezes. Keep *at least* at 1024 MB or more (the default since 0.4.0).

## Good to know

- Put nothing in the shared folder that the AI must not see. The AI is root in its VM.
- Never run a script on Windows that the AI can change. Keep the copy of Terrarium you start
  outside every shared folder, and look at what changed before you use files from there (see
  below for git repositories).
- The default login is user `ai`, password `ai` (for `sudo`). The Terminal button needs no
  password, in the Windows terminal and in PuTTY: it logs in with a key.
- Each VM is stored either in your user folder (`C:\Users\<you>\.aicage`, the default) or in this
  program folder. Terrarium finds VMs in both. The logs, the Debian image and the settings are
  always in `.aicage`. If something fails, the log in `.aicage\logs\` says what happened.
- If Windows blocks the files after downloading: right-click the zip, **Properties**, tick
  **Unblock**, then unzip again.
- To remove everything: delete the VMs with **Remove**, then run `Terrarium.cmd console` and
  `Uninstall-AiCage`, then delete this folder and `.aicage`.

## Git repositories in a shared folder

The VM has no access to your GitHub login: it stays in Windows' Credential Manager, so the AI
cannot push in your name. But it can change the `.git` folder, and some of what is there runs on
Windows when *you* use git: hooks (`.git/hooks/*`) and settings in `.git/config` such as
`core.fsmonitor`, `core.hooksPath` or `core.sshCommand`. Before running git (or Sourcetree) on
Windows in such a folder, check that `.git/hooks` holds only `*.sample` files and that
`.git/config` has nothing you did not put there - or push from a separate clone outside the
shared folder. Anyone can write any name into a commit; sign your commits and turn on GitHub's
*vigilant mode* so that commits not made by you show as *Unverified*.
