# RFC: Explicit session virtual displays

Status: Experimental implementation for review; no hardware acceptance yet.

## Scope

An isolated, user-invoked virtual display session owns private CGVirtualDisplay runtime
objects. It adds endpoints without modifying existing display mode, main-screen,
mirroring or layout state. Settings explicitly enables experimental creation, supplies
the real app safe-mode state, and can remove each endpoint. No automatic resume or
startup restore occurs. Public API only flavor excludes all private-provider wiring.

## Threat and recovery review

Malformed user definitions are rejected before invoking private SPI. Class/selector
preflight and Objective-C exceptions fail closed for absent/rejected interfaces. Creation
and destruction serialize while polling WindowServer; cancellation on creation releases
the object. Failed verification releases the object and reports a timeout. A remaining
physical recovery surface is required before creating a virtual endpoint. Destruction
requires another independent active surface, excluding a mirror slave of that endpoint.
No emergency-command hooks or physical-display writes are installed.

The SPI can change without notice; selector availability does not prove ABI compatibility.
Process termination releases owned endpoints; therefore users must preserve a physical
recovery surface. Session ownership currently follows Settings view lifetime. This is
explicitly an acceptance limitation, not a persistence guarantee. Root may promote session
ownership to AppModel without enabling startup creation. Headless-only use remains denied.

## Validation

Pure Codable/input tests cover corrupt dimensions, empty/null names, NaN/infinite refresh,
HiDPI evenness, accepted boundaries and export roundtrip. Compile checks cover the original
Objective-C bridge and Swift provider. Hardware acceptance must record OS/build/chip,
physical route, displayed desktop, observed physical pixel size, mirror removal behavior,
sleep/wake and crash/relaunch recovery. No hardware acceptance is claimed.
