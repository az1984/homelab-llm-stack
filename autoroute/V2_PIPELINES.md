# AutoRoute Spec Addendum - v2.0 Future Considerations

## v1.0 (Current - Standalone Proxy)

**Architecture:**
- Standalone Python HTTP server
- Single config.yaml file
- No external dependencies (beyond requests/PyYAML)
- Works with any OpenAI-compatible client
- Runs as systemd service or minimal Docker container

**Pros:**
- Minimal moving parts
- Easy to migrate between hardware
- One DNS name, one service
- Universal (not tied to Open WebUI)

**Cons:**
- Configuration via YAML file editing
- No GUI for tuning

## v2.0 (Future - Pipelines Integration)

**When it makes sense:**
- Multi-user Open WebUI deployment
- Preference for GUI-driven configuration
- Want per-user routing overrides
- Willing to manage extra container

**Implementation Notes:**
- Open WebUI Pipelines as middleware
- Valves for admin panel configuration
- Same routing logic, different packaging
- Could coexist with v1.0 (v1.0 as fallback for non-OWUI clients)

**Architecture:**
```
Open WebUI → Pipelines Container → AutoRoute Pipe
                                      ↓
                                  Router Model
                                      ↓
                                  Target VIPs
```

**Valves Configuration:**
- All VIP endpoints configurable via gear icons
- Per-pipeline ripcord settings
- Timeout tuning in admin panel
- Probe configuration toggles

**Benefits over v1.0:**
- No YAML editing
- Click to change endpoints
- Integrated with Open WebUI admin
- Per-user routing policies (advanced)

**Trade-offs:**
- Extra container (Pipelines server)
- Open WebUI specific (loses universality)
- More complexity in stack

## Decision Matrix

Choose **v1.0 Standalone** if:
- ✅ Single user homelab
- ✅ Comfortable with YAML
- ✅ Want minimal services
- ✅ Use multiple clients (not just Open WebUI)
- ✅ Easy hardware migration matters

Choose **v2.0 Pipelines** if:
- ✅ Multi-user deployment
- ✅ Prefer GUI configuration
- ✅ Open WebUI is only client
- ✅ Willing to manage extra container
- ✅ Want user-specific routing policies

## Migration Path (v1.0 → v2.0)

If you start with v1.0 and want v2.0 later:

1. Keep v1.0 running as fallback
2. Deploy Pipelines container
3. Create AutoRoute Pipe (port routing logic)
4. Test Pipe alongside v1.0
5. Switch Open WebUI to Pipe
6. Keep v1.0 for non-OWUI clients

Or:

1. Stop v1.0
2. Convert config.yaml to Pipe Valves
3. Deploy Pipe
4. Point Open WebUI at Pipelines

## Hybrid Approach (Best of Both)

Run **both**:
- v1.0 standalone at `autoroute.local:8080` (universal endpoint)
- v2.0 Pipelines for Open WebUI users who want GUI config

Non-Open WebUI clients use v1.0.  
Open WebUI users can choose v1.0 or v2.0 Pipe.

## Code Reuse

~90% of routing logic is identical:
- Router call logic
- Ripcord detection
- Fallback logic
- Decision application

Only packaging differs:
- v1.0: HTTP server
- v2.0: Pipe class with inlet/outlet

Could maintain shared core module used by both.

## Recommendation for Homelab

**Start with v1.0.** It's simpler, more maintainable, and works for your use case.

Consider v2.0 if:
- You add more users
- GUI config becomes valuable
- Pipelines is already running for other reasons

---

**Current Status: v1.0 implemented and ready to deploy**
