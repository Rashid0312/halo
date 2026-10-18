/* Halo AI — site.js
   Initializes the WebGL fluid mesh gradient, screenshot carousel, and nav active tracking */

(function () {
    'use strict';

    // ── Fluid Aurora Mesh Gradient Initialization ───────────
    function initGradient() {
        const canvas = document.getElementById('gradient-canvas');
        if (!canvas) return;

        if (typeof window.FluidGradient === 'function') {
            const gradient = new window.FluidGradient({
                canvas: canvas,
                colors: [
                    '#3A8EE6', // Sky Azure
                    '#68C4F8', // Luminous Light Blue
                    '#9BE7F6', // Glacier Ice
                    '#FDE4B8', // Soft Sunlight / Champagne
                    '#7DE4D2', // Arctic Seafoam
                    '#1B6ED8'  // Pacific Blue
                ],
                speed: 0.60,
                intensity: 1.05,
                opacity: 0.90,
                grain: 0.022
            });

            // Store instance globally for easy console configuration
            window.haloGradient = gradient;

            // Subtle fade-in
            const container = document.getElementById('heroCanvasContainer');
            if (container) {
                requestAnimationFrame(() => {
                    container.classList.add('visible');
                });
            }
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initGradient);
    } else {
        initGradient();
    }

    // ── Screenshot Carousel ─────────────────────────────────
    const track = document.getElementById('carouselTrack');
    const prevBtn = document.getElementById('carouselPrev');
    const nextBtn = document.getElementById('carouselNext');
    const dots = document.querySelectorAll('.carousel-dots .dot');
    let current = 0;

    function goTo(index) {
        const slides = track ? track.children.length : 0;
        if (!slides) return;
        current = (index + slides) % slides;
        track.style.transform = `translateX(-${current * 100}%)`;
        dots.forEach((d, i) => d.classList.toggle('active', i === current));
    }

    if (prevBtn) prevBtn.addEventListener('click', () => goTo(current - 1));
    if (nextBtn) nextBtn.addEventListener('click', () => goTo(current + 1));
    dots.forEach((dot, i) => dot.addEventListener('click', () => goTo(i)));

    // Auto-advance every 6 seconds
    if (track && track.children.length > 1) {
        setInterval(() => goTo(current + 1), 6000);
    }

    // ── Nav active link on scroll ───────────────────────────
    const sections = document.querySelectorAll('section[id]');
    const navLinks = document.querySelectorAll('.nav-links a[href^="/#"]');

    function updateActiveLink() {
        let currentSectionId = '';
        sections.forEach(section => {
            const top = section.offsetTop - 100;
            if (window.scrollY >= top) currentSectionId = section.id;
        });
        navLinks.forEach(link => {
            const href = link.getAttribute('href');
            link.classList.toggle('active', href === `/#${currentSectionId}`);
        });
    }

    window.addEventListener('scroll', updateActiveLink, { passive: true });

    // ── Siri vs. Halo Comparison Interactive Prompt Switcher ────
    function initSiriComparison() {
        const chips = document.querySelectorAll('.v-chip[data-siri-prompt]');
        const siriText = document.getElementById('siriResponseText');
        const haloText = document.getElementById('haloResponseText');
        const siriFooter = document.querySelector('.siri-reality-card .v-card-bottom');
        const haloFooter = document.querySelector('.halo-reality-card .v-card-bottom');

        if (!chips.length || !siriText || !haloText) return;

        const PROMPT_DATA = {
            notesSlack: {
                siri: `"I found some web search results for 'summarize notes and send confirmed dates to Alex on Slack'. Tap to view in Safari."`,
                siriVerdict: '❌ Web Redirect Dead-End',
                siriNote: 'Zero Accessibility access · Cannot interact with Notes or Slack',
                halo: `"Found <strong>Q4 Launch Strategy</strong> in Notes. Extracted 3 milestones: Oct 24, Nov 2, Nov 15. Drafted confirmation message to Alex Chen in #product-eng. Waiting for your approval."`,
                haloVerdict: '✓ Cross-App Chained Execution',
                haloNote: 'Notes ➔ Slack ➔ Approval Card dispatched in 0.4s'
            },
            xcodeFix: {
                siri: `"I can't inspect other applications running on your Mac. Would you like me to search the web for 'Xcode build failure'?"`,
                siriVerdict: '❌ Blind to Active Screen & Windows',
                siriNote: 'Zero ScreenCaptureKit access · Blind to desktop context',
                halo: `"Screen captured via <strong>ScreenCaptureKit</strong>: Found error in <code>ConversationTests.swift:48</code> — missing protocol conformance for <code>CustomDebugStringConvertible</code>. Fix patch ready."`,
                haloVerdict: '✓ Instant Visual Code Diagnosis',
                haloNote: 'ScreenCaptureKit + Any Vision API in 0.5s'
            },
            cleanDesktop: {
                siri: `"Sorry, I cannot manage, move, or organize files and folders on your Mac."`,
                siriVerdict: '❌ Blocked from Filesystem Actions',
                siriNote: 'No Finder integration · Zero file manipulation capabilities',
                halo: `"Scanned <code>~/Desktop</code>. Located 14 loose screenshot images from October. Created <code>~/Desktop/Archive 2026</code>. Approval card prepared before moving."`,
                haloVerdict: '✓ Approval-Gated File Organization',
                haloNote: '14 files sorted with 1-click Approval Guard'
            }
        };

        chips.forEach(chip => {
            chip.addEventListener('click', () => {
                chips.forEach(c => c.classList.remove('active'));
                chip.classList.add('active');

                const key = chip.getAttribute('data-siri-prompt');
                const data = PROMPT_DATA[key];
                if (!data) return;

                // Animate text transition
                siriText.style.opacity = '0.3';
                haloText.style.opacity = '0.3';

                setTimeout(() => {
                    siriText.innerHTML = data.siri;
                    haloText.innerHTML = data.halo;

                    if (siriFooter) {
                        siriFooter.innerHTML = `
                            <span class="v-verdict-tag fail">${data.siriVerdict}</span>
                            <span class="v-verdict-detail">${data.siriNote}</span>
                        `;
                    }

                    if (haloFooter) {
                        haloFooter.innerHTML = `
                            <span class="v-verdict-tag success">${data.haloVerdict}</span>
                            <span class="v-verdict-detail">${data.haloNote}</span>
                        `;
                    }

                    siriText.style.opacity = '1';
                    haloText.style.opacity = '1';
                }, 150);
            });
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initSiriComparison);
    } else {
        initSiriComparison();
    }

})();

