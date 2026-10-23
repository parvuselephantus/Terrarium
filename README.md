# Terrarium - the AI cage

Isolated Linux (Debian 13) virtual machines for AI agents on Windows. The AI gets full admin
rights inside its VM, the internet and - if you want - one shared folder. It can't see the rest
of your files, your home, office or cowork network, or other VMs.

https://github.com/user-attachments/assets/cb3d2f92-6332-47be-be5d-978e01c5d82f

*The 5-minute introduction: installing, creating a VM, everyday use and what keeps it safe.
Full quality: [terrarium-intro.mp4](https://github.com/parvuselephantus/Terrarium/releases/download/v1.0.0/terrarium-intro.mp4)
([1.0.0 release](https://github.com/parvuselephantus/Terrarium/releases/tag/v1.0.0)).*

Version 1.0.0. Formerly called *AI Cage*: VMs made by AI Cage keep working, and its internal
names (the `.aicage` folder, the `AICage` virtual switch, the `*-Aic*` commands) stay.

## Safety at a glance

The VM is a strong wall; the **shared folder is a door**. Terrarium keeps the AI away from your
files, your laptop's services, your home or office network and your other VMs. It cannot make
safe what you *do* with the AI's files on Windows, or protect secrets you give the AI.

| Option | Default | Risk | Why |
|---|---|---|---|
| Shared folder, writable | on | **High** | What the AI writes can run on Windows when you open or use it (scripts, shortcuts, git hooks, IDE tasks). Tick *read-only* when it only needs to read, or share no folder at all. |
| What you share | your choice | **High** | Terrarium warns (in red, and asks again) when the folder contains Terrarium itself, is synced to the cloud, is a whole Documents/Desktop/Downloads, or holds keys and `.env` files. |
| Network *Open* | off | **High** | The AI reaches your router, NAS, printers, other PCs, the office network. Terrarium asks before switching. |
| Ports to this laptop | none | **Medium** | `localhost` pages from the VM share cookies with your other local apps. To just look, open `http://<VM address>:<port>`. |
| Desktop *with clipboard* | off | **Medium** | Both ways: the VM can read what you copy (often passwords). |
| Desktop | off | **Low** | The VM can draw a fake Windows dialog - never type your Windows password there. |
| Desktop *with sound* | off | **Low** | One more data stream from the VM into Windows' Remote Desktop program. |
| Password `ai` | `ai` | **Low** | Any program on the laptop can log in to the VM. Choose a real one on a shared PC. |
| Start with Windows | on | **Info** | An agent keeps working while you are not looking. |

The dialogs show these risks in amber next to each option, and the **Risks** column lists what
each VM has turned on. Without being asked, *Strict* also blocks networks the laptop reaches
through a VPN, and the VM is not told the laptop's name. **[SECURITY.md](SECURITY.md)** has the
full analysis: threat model, how the cage is built, what is always there (SMB, Hyper-V), and a
checklist.

## You need

- Windows 10 or 11 **Pro, Enterprise or Education** (Home has no Hyper-V)
- Administrator rights, about 10 GB free disk, 8 GB RAM or more

## Start

1. Unzip the folder anywhere, e.g. `C:\Tools\Terrarium`.
2. **Read it before you run it.** Terrarium asks for Administrator rights, so do not take it on
   trust - not even from this page. It is two plain text files: `Terrarium.cmd` (16 lines, it
   only starts the script elevated) and `Terrarium.ps1` (PowerShell, commented). Open them in
   Notepad or VS Code; see [Check it yourself](#check-it-yourself) for what to look at.
3. Double-click **Terrarium.cmd** and allow Administrator rights.
4. The top of the window checks your laptop. If it shows **Fix problems**, click it (for example
   to turn on Hyper-V; Windows then needs a restart).
5. Click **+ New VM**, pick a name and a shared folder (or untick *Share a folder* for a VM that
   sees no file of your laptop), click **Create VM**. It takes 2–3 minutes (the first time it
   downloads Debian, about 420 MB).
6. **Terminal** opens a command line in the VM. The small arrow next to it picks the program: the
   Windows terminal or PuTTY (if installed). The VM sees the shared folder as `~/shared`.
7. Optional, under *Advanced*: install **Docker**, **Claude Code**, **Codex** or a **Desktop**,
   and choose where the VM is stored. **Settings** changes all of this for an existing VM too.

Every new VM is checked automatically. If it can reach something it must not, Terrarium repairs
the protection; if that does not help, it disconnects the VM's network and tells you
(**quarantined**). **Test and secure** runs the check again at any time.

## Desktop

*Desktop (XFCE)* installs a light graphical desktop with Firefox (about 1 GB). The **Desktop**
button opens it in Windows' Remote Desktop; log in with the Linux user and password. The desktop
resizes with the window. Remote Desktop shares nothing of your laptop with the VM - not even the
clipboard, which often holds passwords, unless you tick *with clipboard*.

*with sound* (next to Desktop, also in **Settings**) plays the VM's sound on the laptop, e.g. for
videos. It is off by default: it only goes from the VM to the laptop - the microphone is never
shared - but it gives a VM one more way to talk to Windows' Remote Desktop program. A change
applies from the next Remote Desktop connection.

*with clipboard* (next to it) allows copy and paste between the laptop and the desktop. It works
both ways: while a desktop window is open, the VM can read whatever you copy on Windows -
passwords from a password manager included. Turn it on for a task, off afterwards; it applies
from the next Remote Desktop connection. (Terrarium now sets `redirectclipboard` in the VM's
`.rdp` file itself, so a hand edit there is overwritten.)

The VM can draw anything in the Remote Desktop window, including a copy of a Windows sign-in
dialog: the only password it should ever ask for is the Linux one.

## Ports

*Ports to this laptop* (e.g. `8080, 5432, 3000:80`) makes services in the VM - say a Docker
container published on port 8080 - reachable from apps on your laptop as `localhost:8080`.
`3000:80` means laptop port 3000 to VM port 80. Only your laptop sees them, not your network.
TCP only. Without any forward, the laptop can also open `http://<VM address>:<port>` directly.
The VM still cannot reach anything on your laptop.

Prefer that direct address for *looking at* pages: browsers treat every `localhost` port as the
same site, so a page the VM serves on `localhost:8080` receives the cookies of your other
`localhost` apps. Forward a port only when a Windows program needs it as `localhost`.

## A VM without a shared folder

Untick **Share a folder of this laptop with the VM** in *New VM* or *Settings*. The VM then has no
share, no share account and no way to the laptop's file sharing: a firewall rule blocks port 445
from its address, whatever Windows' own file-sharing rules allow. *Test and secure* checks that
too. Work moves in and out with `git` (push from the
VM, pull on Windows - with a token that can only reach that repository), `scp` from the laptop,
or by ticking the box again later (the VM must be running).

## Networks behind a VPN

*Strict* blocks private address ranges, where home, office and cowork networks live. Company
networks reached over a VPN sometimes use public addresses; so *Strict* also blocks every network
the laptop has its own route to - what a split-tunnel VPN adds, or an office LAN on public
addresses. Terrarium updates this when it starts, on **Check again**, on **Start** and on **Test
and secure** - so after connecting a VPN, click **Check again**. A VPN that sends *all* traffic
through the company (full tunnel) cannot be told apart from the internet: disconnect it while an
agent works. Networks you want blocked in any case go into `config.json` in `.aicage`:

```json
{ "BlockRanges": ["203.0.113.0/24", "198.51.100.0/22"] }
```

`"BlockVpnRoutes": false` turns the automatic part off.

## When a VM does not answer

If the Terminal, PuTTY and the VM's screen stop reacting, the **Health** column usually shows
*not responding*. **Diagnose** looks at what Hyper-V sees (heartbeat, memory), Hyper-V's own
event log for the VM and - once SSH works - the VM's system log of this and the previous boot.
For a stuck VM it offers a restart; Diagnose afterwards explains the stuck boot.

The most common cause is memory: Hyper-V's Dynamic Memory gives an idle VM back to its minimum
and a busy VM then freezes. Keep *at least* at 1024 MB or more (the default since 0.4.0).

## Good to know

- Put nothing in the shared folder that the AI must not see. The AI is root in its VM. Terrarium
  warns when the folder looks risky, but never refuses it.
- The VM is not told the laptop's name, domain or Windows build (Hyper-V's *Data Exchange*
  service is off for Terrarium VMs; older VMs are switched over at the next check). Hyper-V
  Manager therefore shows no address for them - the Terrarium window does.
- Secrets you give the AI (API keys, tokens, the `claude` / `codex` login) can be read and sent
  anywhere by it. Use separate, limited keys for the VM.
- Files the AI wrote are like downloads from the internet: do not double-click them, open the
  folder in your IDE in restricted mode, read diffs before you build or commit on Windows.
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

## Check it yourself

Terrarium runs as Administrator and changes Windows: Hyper-V, a virtual switch and NAT,
firewall rules, a local account and an SMB share per VM, port forwards. Before the first run -
and after every update - it is worth a look:

- **Where it came from.** Download it from the GitHub repository, not from a copy someone sent
  you. With git, `git log` shows who changed what.
- **What it runs.** `Terrarium.cmd` only restarts itself as Administrator and starts
  `Terrarium.ps1`. In the script, nearly every Windows change is logged as a `Cmd` line before it
  runs (`Write-AicLog ... -Level Cmd`), so the log file of a first run shows what was done.
- **What it downloads.** Search the script for `https://`. Windows downloads only the Debian
  image (`cloud.debian.org`, checked against Debian's SHA512 list); Docker, Claude Code and Codex
  - only if you tick them - are fetched from their official sources by the VM, into the VM.
- **No surprises.** No telemetry, no auto-update, nothing runs in the background on Windows
  besides Hyper-V's own VMs and Windows' port forwarding.
- **Ask an AI to review it** - in a Terrarium VM, of course.

## Git repositories in a shared folder

The VM has no access to your GitHub login: it stays in Windows' Credential Manager, so the AI
cannot push in your name. But it can change the `.git` folder, and some of what is there runs on
Windows when *you* use git: hooks (`.git/hooks/*`) and settings in `.git/config` such as
`core.fsmonitor`, `core.hooksPath` or `core.sshCommand`. Before running git (or Sourcetree) on
Windows in such a folder, check that `.git/hooks` holds only `*.sample` files and that
`.git/config` has nothing you did not put there - or push from a separate clone outside the
shared folder. Anyone can write any name into a commit; sign your commits and turn on GitHub's
*vigilant mode* so that commits not made by you show as *Unverified*.

## License

Terrarium is released under the [Apache License 2.0](LICENSE): use it, change it and share it,
also commercially; keep the license and copyright notices, and mark what you changed. It comes
without warranty - which is one more reason to read it before you run it.
