# lgtv.ps1

A PowerShell controller for LG webOS TVs that establishes one of three
absolute machine states — **Personal**, **Work**, or **Off** — by
synchronising the TV's power, the TV's active HDMI input, and the Windows
desktop topology.

The script assumes nothing about the previous state. Every invocation reads
the TV's own answer, sends commands only when the TV disagrees, and
re-verifies the result before declaring success.

---

## The three states

| State      | TV power | TV input               | Windows topology   |
|------------|----------|------------------------|--------------------|
| `Personal` | On       | Personal HDMI          | Extend (2 monitors)|
| `Work`     | On       | Work HDMI              | Internal only      |
| `Off`      | Off      | *(unchanged)*          | Internal only      |

Each state is self-contained. `Off` does not "remember" it followed
`Personal`; `Work` does not assume the TV is already awake. Every
invocation re-establishes the end condition from scratch.

---

## How it works

```mermaid
flowchart TD
    Start([lgtv.ps1 STATE]) --> Mutex{Single instance?}
    Mutex -- no --> Exit0([exit 0])
    Mutex -- yes --> Watchdog[Start 75s watchdog]
    Watchdog --> Store[Initialize-Store]
    Store --> Branch{Which state?}

    Branch -- Off --> OffA[Start display topology: Internal]
    OffA --> OffB{TV reachable?}
    OffB -- no --> OffDone[Already off, success]
    OffB -- yes --> OffC[Connect-TV]
    OffC --> OffD[Subscribe power state]
    OffD --> OffE[ssap://system/turnOff]
    OffE --> OffF{Power push or socket close?}
    OffF --> OffDone
    OffDone --> JoinA[Join display topology]
    JoinA --> Done

    Branch -- Personal/Work --> Resolve[Resolve-TVOnline]
    Resolve --> WOL[Send WOL broadcast + unicast]
    WOL --> Probe{TCP 3001 answers?}
    Probe -- no, timeout --> Rescan[Find-TV subnet sweep]
    Rescan --> Probe
    Probe -- yes --> TopoA{Topology Extend?}

    TopoA -- yes --> DispAsync[Start display topology async]
    TopoA -- no --> SkipDisp[Defer display change]
    DispAsync --> Connect
    SkipDisp --> Connect

    Connect[Connect-TV] --> EWS{Daemon says EWS?}
    EWS -- yes --> Retry[Wait 1s, retry up to 30x]
    Retry --> EWS
    EWS -- no --> Ready[WebSocket registered]
    Ready --> SetInput

    subgraph SetInput [Set-TVInput: read, switch, verify]
        direction TB
        WaitReady[Subscribe power state] --> Push1{Ready push?}
        Push1 -- no --> WaitReady
        Push1 -- yes --> SubFG[Subscribe foreground app]
        SubFG --> ReadFG[GET current foreground app]
        ReadFG --> Match{Matches target?}
        Match -- yes --> Settle
        Match -- no --> Launch[ssap://launcher/launch]
        Launch --> AwaitPush{Foreground push arrives?}
        AwaitPush -- timeout --> ReadFG
        AwaitPush -- yes --> ReadFG
        Settle[2s listen-only settle window] --> Held{Input held?}
        Held -- no, TV changed app --> ReadFG
        Held -- yes --> Verified[Input verified]
    end

    Verified --> TopoB{Topology Internal?}
    TopoB -- yes --> DispSync[Start display topology]
    TopoB -- no --> JoinB[Complete display topology]
    DispSync --> JoinB
    JoinB --> Check{All pieces confirmed?}
    Check -- no --> Fail([exit 1])
    Check -- yes --> Done([exit 0])
