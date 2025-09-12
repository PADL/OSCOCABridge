# OSCOCABridge

OSCOCABridge is allows OCA devices implemented with [SwiftOCA](https://github.com/PADL/SwiftOCA) to also handle OSC messages.

OSC address patterns consist of the OCA role name concatenated with the string encoding of the method name. For example, to set the gain to 0.0 with [osc-utility](https://github.com/72nd/osc-utility) and the included example program:

```bash
osc-utility m --host 127.0.0.1 --port 8000 --address /Block/Gain/4.2 --float 0.0
```

OSCOCABridge uses OSCKitCore from [OSCKit](https://github.com/orchetect/OSCKit).

