# OSCOCABridge

OSCOCABridge allows OCA devices implemented with [SwiftOCA](https://github.com/PADL/SwiftOCA) to also handle OSC messages, and sends OSC clients the changes they subscribe to.

## Addresses

The OSC address space is the device's object tree. An object is addressed by its role path, and the last component of the address names one of its members:

| Last component | Example | Meaning |
|---|---|---|
| Method ID, dotted or AES70 notation | `/Block/Gain/4.2`, `/Block/Gain/4m2` | Invokes the method with the message's arguments |
| Property ID, AES70 notation | `/Block/Gain/4p1` | The property |
| Property name | `/Block/Gain/gain` | The property |
| Method name | `/Block/Gain/setGain` | Invokes the method |

The last component is matched in that order. Names are matched exactly, in lower camel case: `gain`, not `Gain`. A dotted ID is always a method ID; write `4p1` for a property ID.

A property is read by sending its address with no arguments: the bridge replies to the sender on the same address. With arguments, it is set, the arguments being converted to the property's type (so an `OcaMute`'s `state` is a Boolean in OSC, true for muted).

Errors are reported to the sender as `/error ,ss <address> <reason>`.

## Subscriptions

```
/subscribe ,s <address>… [,i port]
/unsubscribe ,s <address>… [,i port]
```

`/subscribe` sends the sender the current value of each property named, then every change to it, on the address as it was subscribed with. Addresses may use OSC wildcards (`/Block/*/gain`); with none, every property is subscribed to. Changes are sent to the sender's address, or to the given port on its host, for a client such as TouchOSC that receives on a port of its own. `/unsubscribe` with no addresses removes all of the sender's subscriptions.

`OSCOCABridge(address:device:subscriptionLifetime:)` can expire a client's subscriptions once nothing has been heard from its host for that long. `addDestination(_:patterns:)` sends changes to a fixed address without the client subscribing.

## Examples

With [osc-utility](https://github.com/72nd/osc-utility) and the included example program, which listens for OSC on port 8000:

```bash
osc-utility m --host 127.0.0.1 --port 8000 --address /Block/Gain/gain --float 0.0
osc-utility m --host 127.0.0.1 --port 8000 --address /Block/Gain/4.2 --float 0.0
```

In TouchOSC, give a fader the address `/Block/Gain/gain` and a UDP connection to the bridge, and subscribe when the layout starts:

```lua
function init()
  sendOSC('/subscribe', '/Block/Gain/gain', 9001) -- 9001: the connection's receive port
end
```

The fader then follows the gain however it is changed.

OSCOCABridge uses [swift-osc-core](https://github.com/orchetect/swift-osc-core).
