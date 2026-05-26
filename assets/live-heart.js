/* live-heart.js — syncs heartbeat animation to Polar H10 RR interval
 *
 * window._liveRrMs is written by a Dash clientside callback whenever the
 * fast callback updates the live-rr-ms Store.  This rAF loop reads it and
 * directly patches the CSS animation-duration on #live-heart-pulse, bypassing
 * React so the animation never restarts mid-beat.
 */

window._liveRrMs = 857;   /* default ~70 BPM before first callback fires */

(function () {
    var _prev = 0;

    function _tick() {
        requestAnimationFrame(_tick);

        var rr = window._liveRrMs;
        if (rr === _prev) return;                 /* no change — skip DOM write */
        if (rr < 300 || rr > 2500) return;        /* sanity-guard artefacts     */

        var el = document.getElementById('live-heart-pulse');
        if (!el) return;

        el.style.animationDuration = rr + 'ms';
        _prev = rr;
    }

    requestAnimationFrame(_tick);
})();
