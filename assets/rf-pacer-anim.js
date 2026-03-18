/* rf-pacer-anim.js — 60 fps breathing-circle animation
 *
 * Reads window._rfPacerParams (set by Dash clientside callback as a side
 * effect) and directly mutates DOM at native frame rate — completely
 * bypassing React so there are zero re-render stalls or transition gaps.
 *
 * window._rfPacerParams fields (all set by the Dash callback):
 *   is_running  bool
 *   is_sound_on bool
 *   inhale_s    number   (seconds per inhale phase)
 *   exhale_s    number   (seconds per exhale phase)
 *   start_ts    number   (Date.now()/1000 at session/BPM start)
 *   min_s       number   (inner-guide px / 160 — exhale resting scale)
 *   max_s       number   (outer-guide px / 160 — inhale peak scale)
 */

(function () {

    /* Default params — active before the first Dash callback fires so the
       rAF loop can render the READY state immediately.                     */
    window._rfPacerParams = {
        is_running:  false,
        is_sound_on: true,
        inhale_s:    4.0,
        exhale_s:    6.0,
        start_ts:    0,
        min_s:       0.8125,   /* 130 / 160 — default 6 BPM inner ring */
        max_s:       1.3875    /* 222 / 160 — default 6 BPM outer ring */
    };

    var _lastAudioMs = 0;
    var _AUDIO_MS    = 100;   /* throttle audio updates to ~10 fps */

    function _tick() {
        requestAnimationFrame(_tick);

        var ring = document.getElementById('rf-pacer-ring');
        if (!ring) return;   /* DOM not yet mounted — skip silently */

        var label     = document.getElementById('rf-phase-label');
        var countdown = document.getElementById('rf-phase-countdown');
        var center    = document.getElementById('rf-pacer-center-text');

        var p = window._rfPacerParams;

        /* ── Idle / paused ──────────────────────────────────────────────── */
        if (!p || !p.is_running) {
            ring.style.transform       = 'scale(1.0)';
            ring.style.border          = '2px solid rgba(129,140,248,0.35)';
            ring.style.backgroundColor = 'rgba(129,140,248,0.06)';
            ring.style.boxShadow       = '';

            if (label) {
                label.textContent = 'READY';
                label.style.color = '#818cf8';
            }
            if (countdown) { countdown.textContent = ''; }
            if (center) {
                center.textContent   = '';
                center.style.opacity = '0';
            }

            /* Stop audio (no-op if already stopped) */
            var nowMs = Date.now();
            if (nowMs - _lastAudioMs >= _AUDIO_MS) {
                _lastAudioMs = nowMs;
                window._rfPacerStop && window._rfPacerStop();
            }
            return;
        }

        /* ── Timing ─────────────────────────────────────────────────────── */
        var now     = Date.now() / 1000.0;
        var elapsed = now - p.start_ts;
        var cycle   = p.inhale_s + p.exhale_s;
        /* guard against negative elapsed on first tick after start_ts update */
        var phase_t = ((elapsed % cycle) + cycle) % cycle;
        var is_inh  = phase_t < p.inhale_s;

        var progress, remaining, color;

        if (is_inh) {
            progress  = phase_t / p.inhale_s;
            remaining = p.inhale_s - phase_t;
            color     = '#818cf8';   /* indigo — inhale */
        } else {
            var ep   = phase_t - p.inhale_s;
            progress  = ep / p.exhale_s;
            remaining = p.exhale_s - ep;
            color     = '#56d364';   /* green — exhale */
        }

        /* ── Sinusoidal ease-in-out (organic breathing feel) ───────────── */
        var eased = (1 - Math.cos(progress * Math.PI)) / 2;

        /* Inhale EXPANDS (min → max), Exhale CONTRACTS (max → min) */
        var scale = is_inh
            ? p.min_s + (p.max_s - p.min_s) * eased
            : p.max_s - (p.max_s - p.min_s) * eased;

        var glow  = is_inh ? (6 + 28 * eased) : (6 + 28 * (1 - eased));
        var alpha = 0.06 + 0.18 * (is_inh ? eased : 1 - eased);

        /* ── Ring DOM writes ────────────────────────────────────────────── */
        ring.style.transform       = 'scale(' + scale.toFixed(4) + ')';
        ring.style.border          = '2px solid ' + color;
        ring.style.backgroundColor = 'rgba(129,140,248,' + alpha.toFixed(3) + ')';
        ring.style.boxShadow       = '0 0 ' + glow.toFixed(0) + 'px ' + color;

        /* ── Label DOM writes ───────────────────────────────────────────── */
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

        /* ── Audio (throttled — same cadence as old 100 ms Dash interval) ─ */
        var nowMs2 = Date.now();
        if (nowMs2 - _lastAudioMs >= _AUDIO_MS) {
            _lastAudioMs = nowMs2;

            if (p.is_sound_on) {
                var F_LOW = 150, F_HIGH = 450;
                var tFreq = is_inh
                    ? F_LOW  + (F_HIGH - F_LOW) * eased   /* rising  */
                    : F_HIGH - (F_HIGH - F_LOW) * eased;  /* falling */
                var tVol  = is_inh
                    ? 0.07 + 0.13 * eased                 /* louder as lungs fill  */
                    : 0.20 - 0.13 * eased;                /* quieter as lungs empty */
                window._rfPacerBreath && window._rfPacerBreath(tFreq, tVol);
            } else {
                window._rfPacerStop && window._rfPacerStop();
            }
        }
    }

    /* Start loop — requestAnimationFrame is safe to call before DOMContentLoaded;
       the inner `if (!ring) return` guard handles the pre-mount frames.          */
    requestAnimationFrame(_tick);

})();
