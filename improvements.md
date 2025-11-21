# vLLM Connection Script Improvements

## Overview
This document tracks planned improvements and enhancements for the Alvis vLLM connection automation script.

---

## Priority 0: Immediate Improvements



---

## Priority 1: Enhanced Job Monitoring

### GPU Availability Display
**Status**: Planned
**Priority**: High
**Effort**: Low

**Description**:
Show available A40 GPU resources before job submission to set user expectations.

**Implementation Details**:
- Add to `preflight_checks()` function
- Query SLURM for available GPU resources
- Display: "Available A40 GPUs: 3/12 (25% available)"

**SLURM Commands**:
```bash
# Check GPU availability
sinfo -p alvis -o '%20N %.6D %.6t %.14C %.8G' | grep A40
```

**Benefits**:
- Users know upfront if cluster is busy
- Can decide to wait or try later
- Better expectation management

---

## Priority 2: Estimated Wait Time

### Wait Time Prediction
**Status**: Planned
**Priority**: Medium
**Effort**: High

**Description**:
Provide estimated wait time based on queue position and historical job completion rates.

**Implementation Details**:
- Track average job start time for similar resource requests
- Calculate based on: queue position × average wait per position
- Display: "Estimated wait: ~5 minutes (based on current queue)"
- Store statistics in `~/.vllm-stats.json`

**Algorithm**:
```bash
# Pseudo-code
avg_wait_time = total_recent_wait_times / num_recent_jobs
estimated_wait = queue_position * avg_wait_time / total_positions
```

**Benefits**:
- Users can plan accordingly
- Reduces anxiety during wait
- Data-driven expectations

---

## Priority 2: State Transition Timestamps

### Detailed State Tracking
**Status**: Planned
**Priority**: Medium
**Effort**: Low

**Description**:
Log all state transitions with timestamps for debugging and performance analysis.

**Implementation Details**:
- Create state transition log in `~/.vllm-transitions.log`
- Format: `[TIMESTAMP] JOB_ID: STATE_FROM → STATE_TO (duration: Xs)`
- Example: `[2025-11-21 19:42:00] 5385105: CONFIGURING → RUNNING (duration: 30s)`

**Benefits**:
- Historical data for performance analysis
- Debugging stuck jobs
- Understanding cluster patterns

---

## Priority 3: Session Recovery

### Reconnect to Existing Jobs
**Status**: Planned (commented in code line 471)
**Priority**: Medium
**Effort**: High

**Description**:
Allow users to reconnect to existing running vLLM jobs instead of always starting new ones.

**Implementation Details**:
- Add `--reconnect` flag
- Read from `~/.vllm-session` file
- Check if job is still running
- Reestablish SSH tunnel to existing server
- Validate server is responsive

**Usage**:
```bash
./vllm-connect.sh --reconnect
```

**Benefits**:
- Avoid resource waste from multiple jobs
- Survive network disconnections
- Better resource utilization

---

## Priority 3: Interactive Mode

### User Prompts During Wait
**Status**: Planned
**Priority**: Low
**Effort**: Medium

**Description**:
Add interactive prompts during long waits to give users options.

**Implementation Details**:
- If wait time > 2 minutes, prompt: "Job still waiting (3m). Options: [C]ontinue, [A]bort, [I]nfo"
- Info option shows detailed queue status
- Continue keeps waiting
- Abort cancels job gracefully

**Benefits**:
- Better user control
- Reduced frustration during long waits
- Flexibility for user decisions

---

## Priority 4: Multi-Model Support

### Parallel Model Serving
**Status**: Planned
**Priority**: Low
**Effort**: High

**Description**:
Support running multiple models simultaneously on different nodes/GPUs.

**Implementation Details**:
- Accept multiple `-m` flags
- Submit separate jobs for each model
- Assign different local ports (58000, 58001, etc.)
- Track multiple sessions in `~/.vllm-sessions/`

**Usage**:
```bash
./vllm-connect.sh -m gpt-oss-20b -m llama-2-7b
```

**Benefits**:
- Model comparison workflows
- Parallel experimentation
- Efficient resource utilization

---

## Priority 4: Health Monitoring

### Continuous Server Health Checks
**Status**: Planned
**Priority**: Low
**Effort**: Medium

**Description**:
Periodically check server health and alert on issues.

**Implementation Details**:
- Background process pings `/v1/models` every 30s
- Monitor response time and error rates
- Alert if server becomes unresponsive
- Automatic reconnection attempts

**Benefits**:
- Early detection of issues
- Better reliability
- Automatic recovery from transient failures

---

## Technical Debt

### Code Refactoring
- [ ] Extract SLURM query functions into separate module
- [ ] Add unit tests for parsing functions
- [ ] Improve error messages with recovery suggestions
- [ ] Add debug mode (`--debug` flag) with verbose logging

### Documentation
- [ ] Add troubleshooting guide
- [ ] Document all configuration options
- [ ] Add architecture diagram
- [ ] Create video tutorial

---

## Implementation Priority

**Phase 1** (Next release):
- Queue position display
- GPU availability information
- State transition logging

**Phase 2** (Future):
- Estimated wait time
- Session recovery
- Interactive mode

**Phase 3** (Long-term):
- Multi-model support
- Health monitoring
- Performance analytics dashboard

---

## Contributing

To propose new improvements:
1. Add to this document under appropriate priority
2. Include implementation details and benefits
3. Estimate effort (Low/Medium/High)
4. Discuss in issues before implementation
