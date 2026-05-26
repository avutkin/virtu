/* rf-pacer-anim.js — 60 fps breathing-circle animation with smooth BPM transitions
 *
 * Two global objects:
 *   window._rfPacerParams  — currently active params (applied immediately)
 *   window._rfPacerNext    — pending BPM change; applied by rAF at the NEXT
 *                            natural inhale boundary so breathing never jumps
 *
 * Fields (both objects):
 *   is_running   bool
 *   is_sound_on  bool
 *   inhale_s     number   (seconds per inhale phase)
 *   exhale_s     number   (seconds per exhale phase)
 *   start_ts     number   (overridden by rAF when applying _rfPacerNext)
 *   min_s        number   (exhale resting scale)
 *   max_s        number   (inhale peak scale)
 */

(function () {

    window._rfPacerParams = {
        is_running:  false,
        is_sound_on: true,
        inhale_s:    4.0,
        exhale_s:    6.0,
        start_ts:    0,
        min_s:       0.8125,
        max_s:       1.3875
    };
    window._rfPacerNext = null;   /* queued BPM change — applied at inhale boundary */

    var _lastAudioMs = 0;
    var _AUDIO_MS    = 100;

    /* Previous tick's phase_t — used for cycle-boundary detection */
    var _prevPhaseT = -1;

    /* Smooth min_s / max_s lerp across BPM changes */
    var _lerpFromMin = null;
    var _lerpFromMax = null;
    var _lerpStart   = 0;
    var _LERP_SECS   = 2.0;

    function _tick() {
        requestAnimationFrame(_tick);

        var ring = document.getElementById('rf-pacer-ring');
        if (!ring) return;

        var label     = document.getElementById('rf-phase-label');
        var countdown = document.getElementById('rf-phase-countdown');
        var center    = document.getElementById('rf-pacer-center-text');

        var p   = window._rfPacerParams;
        var now = Date.now() / 1000.0;

        /* ── Pending BPM transition ──────────────────────────────────────────
           If not running (start / stop / reset) → apply immediately.
           If running → running → defer until the next inhale boundary so the
           user completes the current breath before the new tempo begins.      */
        if (window._rfPacerNext !== null) {
            var next = window._rfPacerNext;

            if (!next.is_running || !p.is_running) {
                /* Start or stop — apply immediately, reset lerp */
                _lerpFromMin = null;
                _lerpFromMax = null;
                _prevPhaseT  = -1;
                p = window._rfPacerParams = next;
                window._rfPacerNext = null;

            } else {
                /* Running → running: detect cycle boundary */
                var old_cycle = p.inhale_s + p.exhale_s;
                var elapsed   = now - p.start_ts;
                var phase_t   = ((elapsed % old_cycle) + old_cycle) % old_cycle;

                /* Boundary: prev tick was in the last 20% of cycle AND
                   current tick is in the first 20%.                       */
                var at_boundary = (_prevPhaseT  >= 0)
                               && (_prevPhaseT   > old_cycle * 0.80)
                               && (phase_t       < old_cycle * 0.20);

                if (at_boundary) {
                    /* Latch current scale bounds for smooth lerp */
                    _lerpFromMin = p.min_s;
                    _lerpFromMax = p.max_s;
                    _lerpStart   = now;

                    /* Apply new params; override start_ts with client time
                       so phase_t = 0 exactly here (inhale starts cleanly). */
                    next.start_ts = now;
                    p = window._rfPacerParams = next;
                    window._rfPacerNext = null;
                    _prevPhaseT = 0;
                } else {
                    _prevPhaseT = phase_t;
                }
            }
        }

        /* ── Idle / paused ──────────────────────────────────────────────────── */
        if (!p || !p.is_running) {
            ring.style.transform       = 'scale(1.0)';
            ring.style.border          = '2px solid rgba(129,140,248,0.35)';
            ring.style.backgroundColor = 'rgba(129,140,248,0.06)';
            ring.style.boxShadow       = '';

            if (label)     { label.textContent = 'READY'; label.style.color = '#818cf8'; }
            if (countdown) { countdown.textContent = ''; }
            if (center)    { center.textContent = ''; center.style.opacity = '0'; }

            _lerpFromMin = null;
            _lerpFromMax = null;

            var nowMs = Date.now();
            if (nowMs - _lastAudioMs >= _AUDIO_MS) {
                _lastAudioMs = nowMs;
                window._rfPacerStop && window._rfPacerStop();
            }
            return;
        }

        /* ── Timing ─────────────────────────────────────────────────────────── */
        var elapsed2 = now - p.start_ts;
        var cycle    = p.inhale_s + p.exhale_s;
        var phase_t2 = ((elapsed2 % cycle) + cycle) % cycle;
        var is_inh   = phase_t2 < p.inhale_s;

        /* Track phase for next frame's boundary check */
        if (window._rfPacerNext === null) { _prevPhaseT = phase_t2; }

        var progress, remaining, color;
        if (is_inh) {
            progress  = phase_t2 / p.inhale_s;
            remaining = p.inhale_s - phase_t2;
            color     = '#818cf8';
        } else {
            var ep   = phase_t2 - p.inhale_s;
            progress  = ep / p.exhale_s;
            remaining = p.exhale_s - ep;
            color     = '#56d364';
        }

        /* ── Sinusoidal ease-in-out ──────────────────────────────────────────── */
        var eased = (1 - Math.cos(progress * Math.PI)) / 2;

        /* ── Lerped scale bounds (smooth min/max transition over 2 s) ───────── */
        var eff_min, eff_max;
        if (_lerpFromMin !== null) {
            var t_lerp = Math.min(1.0, (now - _lerpStart) / _LERP_SECS);
            eff_min = _lerpFromMin + (p.min_s - _lerpFromMin) * t_lerp;
            eff_max = _lerpFromMax + (p.max_s - _lerpFromMax) * t_lerp;
            if (t_lerp >= 1.0) { _lerpFromMin = null; _lerpFromMax = null; }
        } else {
            eff_min = p.min_s;
            eff_max = p.max_s;
        }

        var scale = is_inh
            ? eff_min + (eff_max - eff_min) * eased
            : eff_max - (eff_max - eff_min) * eased;
        var glow  = is_inh ? (6 + 28 * eased) : (6 + 28 * (1 - eased));
        var alpha = 0.06 + 0.18 * (is_inh ? eased : 1 - eased);

        /* ── Ring DOM writes ─────────────────────────────────────────────────── */
        ring.style.transform       = 'scale(' + scale.toFixed(4) + ')';
        ring.style.border          = '2px solid ' + color;
        ring.style.backgroundColor = 'rgba(129,140,248,' + alpha.toFixed(3) + ')';
        ring.style.boxShadow       = '0 0 ' + glow.toFixed(0) + 'px ' + color;

        /* ── Label DOM writes ────────────────────────────────────────────────── */
        if (label) {
            label.textContent = is_inh ? 'INHALE' : 'EXHALE';
            label.style.color = color;
        }
        if (countdown) {
            countdown.textContent = remaining.toFixed(1) + 's';
        }
        if (center) {
            var secR             = Math.floor(remaining);
            center.textContent   = secR > 0 ? String(secR) : '';
            center.style.color   = color;
            center.style.opacity = '1';
        }

        /* ── Audio (throttled ~10 fps) ───────────────────────────────────────── */
        var nowMs2 = Date.now();
        if (nowMs2 - _lastAudioMs >= _AUDIO_MS) {
            _lastAudioMs = nowMs2;
            if (p.is_sound_on) {
                var F_LOW = 150, F_HIGH = 450;
                var tFreq = is_inh
                    ? F_LOW  + (F_HIGH - F_LOW) * eased
                    : F_HIGH - (F_HIGH - F_LOW) * eased;
                var tVol  = is_inh
                    ? 0.07 + 0.13 * eased
                    : 0.20 - 0.13 * eased;
                window._rfPacerBreath && window._rfPacerBreath(tFreq, tVol);
            } else {
                window._rfPacerStop && window._rfPacerStop();
            }
        }
    }

    requestAnimationFrame(_tick);

})();
