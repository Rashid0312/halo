/**
 * Living macOS Desktop Interactive Simulator
 * Matches the native SwiftUI Halo panel (PanelDesign.swift) and authentic macOS Sonoma desktop.
 */
(function () {
    'use strict';

    document.addEventListener('DOMContentLoaded', initLivingDesktop);

    function initLivingDesktop() {
        const desktopWrapper = document.getElementById('livingDesktop');
        if (!desktopWrapper) return;

        // Interactive UI Elements
        const menuBarPill = document.getElementById('menuBarHaloPill');
        const pillStatusText = document.getElementById('pillStatusText');
        const haloPanel = document.getElementById('haloLivingPanel');
        const desktopCapsule = document.getElementById('mercyDesktopCapsule');
        const retractBtn = document.getElementById('panelRetractBtn');
        const pinBtn = document.getElementById('panelPinBtn');
        const btnToggleOpen = document.getElementById('btnToggleOpen');
        const btnToggleClosed = document.getElementById('btnToggleClosed');
        const promptChips = document.querySelectorAll('.desktop-prompt-chip');

        // Panel Dynamic Elements
        const haloUserText = document.getElementById('haloUserText');
        const haloAssistantText = document.getElementById('haloAssistantText');
        const activityCard = document.getElementById('nativeActivityCard');
        const activityHeaderToggle = document.getElementById('activityHeaderToggle');
        const activityTitleText = document.getElementById('activityTitleText');
        const activityTimerText = document.getElementById('activityTimerText');
        const activityStepsList = document.getElementById('activityStepsList');
        const approvalCard = document.getElementById('haloApprovalCard');
        const btnApproveSend = document.getElementById('btnApproveSend');
        const btnCancelSend = document.getElementById('btnCancelSend');
        const composerInput = document.getElementById('panelInputComposer');
        const composerSendBtn = document.getElementById('composerSendBtn');

        // Notes Window Elements
        const notesTimestamp = document.getElementById('notesTimestamp');
        const checkItem1 = document.getElementById('checkItem1');
        const checkItem2 = document.getElementById('checkItem2');
        const checkItem3 = document.getElementById('checkItem3');
        const checkItem4 = document.getElementById('checkItem4');
        const notesDynamicAppend = document.getElementById('notesDynamicAppend');
        const menubarActiveApp = document.getElementById('menubarActiveApp');

        let isRunningDemo = false;
        let animationTimeout = null;

        // ── Retract & Expand Panel Logic (PanelDesign.swift match) ────
        function setPanelState(open) {
            if (open) {
                desktopWrapper.classList.remove('is-collapsed');
                if (btnToggleOpen) btnToggleOpen.classList.add('active');
                if (btnToggleClosed) btnToggleClosed.classList.remove('active');
                if (menuBarPill) menuBarPill.classList.add('pill-active');
                if (pillStatusText) pillStatusText.textContent = '"Mercy"';
                if (menubarActiveApp) menubarActiveApp.textContent = 'Halo';
            } else {
                desktopWrapper.classList.add('is-collapsed');
                if (btnToggleOpen) btnToggleOpen.classList.remove('active');
                if (btnToggleClosed) btnToggleClosed.classList.add('active');
                if (menuBarPill) menuBarPill.classList.remove('pill-active');
                if (pillStatusText) pillStatusText.textContent = 'Mercy';
                if (menubarActiveApp) menubarActiveApp.textContent = 'Notes';
            }
        }

        // Toggle triggers
        if (desktopCapsule) {
            desktopCapsule.addEventListener('click', () => setPanelState(true));
        }

        if (retractBtn) {
            retractBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                setPanelState(false);
            });
        }

        if (menuBarPill) {
            menuBarPill.addEventListener('click', (e) => {
                e.stopPropagation();
                const isCurrentlyCollapsed = desktopWrapper.classList.contains('is-collapsed');
                setPanelState(isCurrentlyCollapsed);
            });
        }

        if (btnToggleOpen) {
            btnToggleOpen.addEventListener('click', () => setPanelState(true));
        }

        if (btnToggleClosed) {
            btnToggleClosed.addEventListener('click', () => setPanelState(false));
        }

        if (pinBtn) {
            pinBtn.addEventListener('click', () => {
                pinBtn.classList.toggle('pinned');
                pinBtn.style.color = pinBtn.classList.contains('pinned') ? '#9be3f2' : '';
            });
        }

        // Activity steps accordion toggle
        if (activityHeaderToggle && activityCard) {
            activityHeaderToggle.addEventListener('click', () => {
                activityCard.classList.toggle('is-collapsed');
            });
        }

        // Helper to flash highlight scan on notes checklist items
        function triggerNotesScan() {
            const items = [checkItem1, checkItem2, checkItem3, checkItem4];
            items.forEach((item, i) => {
                if (!item) return;
                setTimeout(() => {
                    item.classList.add('highlight-scan');
                    setTimeout(() => item.classList.remove('highlight-scan'), 800);
                }, i * 220);
            });
        }

        // ── Scenario Definitions ──────────────────────────────────────
        const SCENARIOS = {
            notesSlack: {
                userPrompt: '"Hey Mercy, summarize Notes and send confirmed dates to Alex on Slack."',
                activityTitle: 'Reading Notes.app & preparing Slack draft',
                timerText: '0.4s',
                actionOnNotes: () => {
                    triggerNotesScan();
                },
                steps: [
                    { title: 'Read Notes.app: Q4 Launch Strategy', time: '0.1s' },
                    { title: 'Extracted 3 launch milestones (Oct 24, Nov 2, Nov 15)', time: '0.2s' },
                    { title: 'Resolved recipient: Alex Chen (#product-eng)', time: '0.3s' },
                    { title: 'Drafted Slack message with confirmation payload', time: '0.4s' }
                ],
                assistantHtml: `
                    <p class="assistant-p">Found <strong>Q4 Launch Strategy</strong> in Notes. Milestones confirmed: Architecture review Oct 24, Dogfooding Nov 2nd, Public Release Nov 15th.</p>
                    <p class="assistant-p muted">Drafted confirmation message for Slack. Approval required below.</p>
                `,
                showApproval: true
            },
            addChecklist: {
                userPrompt: '"Complete Architecture signoff & add Nov release note"',
                activityTitle: 'Modifying Notes.app checklist item',
                timerText: '0.3s',
                actionOnNotes: () => {
                    if (checkItem2) {
                        checkItem2.classList.add('highlight-scan');
                        setTimeout(() => {
                            checkItem2.classList.add('done');
                            const box = checkItem2.querySelector('.chk-box');
                            if (box) box.textContent = '✓';
                            const badge = checkItem2.querySelector('.chk-badge');
                            if (badge) {
                                badge.className = 'chk-badge success';
                                badge.textContent = 'Completed';
                            }
                            if (notesTimestamp) notesTimestamp.textContent = 'Edited just now by Mercy';
                        }, 500);
                    }
                },
                steps: [
                    { title: 'Located checklist item: Architecture signoff', time: '0.1s' },
                    { title: 'Marked milestone completed in iCloud Notes', time: '0.2s' },
                    { title: 'Updated timestamp & synced database', time: '0.3s' }
                ],
                assistantHtml: `
                    <p class="assistant-p success" style="color: #38df7b;">✓ Completed "Architecture signoff &amp; security review" in Notes.</p>
                    <p class="assistant-p muted">Marked status as completed and synced changes to iCloud.</p>
                `,
                showApproval: false
            },
            researchM4: {
                userPrompt: '"Research M4 benchmarks and append to Notes"',
                activityTitle: 'Querying Apple Silicon benchmarks & appending note',
                timerText: '0.5s',
                actionOnNotes: () => {
                    if (notesDynamicAppend) {
                        notesDynamicAppend.innerHTML = `
                            <strong>⚡ M4 Neural Engine Benchmark:</strong><br>
                            • 38 TOPS NPU throughput (+32% vs M3)<br>
                            • DeepSeek V3 audio token latency: 184ms<br>
                            • Zero cloud round-trips for local voice loop
                        `;
                        notesDynamicAppend.style.display = 'block';
                        if (notesTimestamp) notesTimestamp.textContent = 'Appended M4 specs just now';
                    }
                },
                steps: [
                    { title: 'Queried Apple Silicon M4 NPU benchmarks', time: '0.2s' },
                    { title: 'Verified 38 TOPS throughput & 184ms latency', time: '0.3s' },
                    { title: 'Appended formatted block to Notes canvas', time: '0.5s' }
                ],
                assistantHtml: `
                    <p class="assistant-p">Researched M4 Neural Engine benchmarks.</p>
                    <p class="assistant-p muted">Appended benchmark specs (38 TOPS, 184ms local voice latency) to the active note canvas.</p>
                `,
                showApproval: false
            },
            draftSlack: {
                userPrompt: '"Draft #product-eng release update from Notes"',
                activityTitle: 'Formatting Slack release message',
                timerText: '0.3s',
                actionOnNotes: () => {
                    triggerNotesScan();
                },
                steps: [
                    { title: 'Parsed checklist items from Notes.app', time: '0.1s' },
                    { title: 'Formatted markdown announcement for Slack', time: '0.2s' },
                    { title: 'Ready for one-click dispatch to #product-eng', time: '0.3s' }
                ],
                assistantHtml: `
                    <p class="assistant-p">Formatted the release update based on current Notes progress:</p>
                    <p class="assistant-p" style="font-family: monospace; font-size: 10px; background: rgba(0,0,0,0.25); padding: 6px 8px; border-radius: 6px; margin-top: 4px;">
                        📢 <strong>Q4 Update</strong>: Voice analyzer tuned. Architecture signoff verified. Dogfooding set for Nov 2!
                    </p>
                `,
                showApproval: true
            }
        };

        function runScenario(key) {
            if (isRunningDemo) return;
            const scenario = SCENARIOS[key];
            if (!scenario) return;

            isRunningDemo = true;
            setPanelState(true);

            // Populate user prompt
            if (haloUserText) haloUserText.textContent = scenario.userPrompt;
            if (activityTitleText) activityTitleText.textContent = scenario.activityTitle;
            if (activityTimerText) activityTimerText.textContent = scenario.timerText;
            if (haloAssistantText) {
                haloAssistantText.innerHTML = '<p class="assistant-p muted">Analyzing macOS screen &amp; active Notes context...</p>';
            }

            // Run action on Notes
            if (typeof scenario.actionOnNotes === 'function') {
                scenario.actionOnNotes();
            }

            // Populate activity steps with realistic stagger
            if (activityStepsList) {
                activityStepsList.innerHTML = '';
                scenario.steps.forEach((s, idx) => {
                    setTimeout(() => {
                        const stepEl = document.createElement('div');
                        stepEl.className = 'act-step done';
                        stepEl.innerHTML = `<span class="step-icon">✓</span><span>${s.title}</span><span class="step-time">${s.time}</span>`;
                        activityStepsList.appendChild(stepEl);
                    }, (idx + 1) * 200);
                });
            }

            setTimeout(() => {
                if (haloAssistantText) haloAssistantText.innerHTML = scenario.assistantHtml;
                if (approvalCard) {
                    approvalCard.style.display = scenario.showApproval ? 'block' : 'none';
                }
                isRunningDemo = false;
            }, (scenario.steps.length + 1) * 200);
        }

        // Chip Clicks
        promptChips.forEach(chip => {
            chip.addEventListener('click', () => {
                promptChips.forEach(c => c.classList.remove('active'));
                chip.classList.add('active');
                const scenarioKey = chip.getAttribute('data-scenario');
                runScenario(scenarioKey);
            });
        });

        // Approval Actions
        if (btnApproveSend && approvalCard) {
            btnApproveSend.addEventListener('click', () => {
                approvalCard.innerHTML = `
                    <div style="color: #166534; font-size: 11px; font-weight: 600; display: flex; align-items: center; gap: 6px; padding: 4px 0;">
                        <span>✓</span><span>Slack message delivered to Alex Chen in #product-eng</span>
                    </div>
                `;
                setTimeout(() => {
                    approvalCard.style.display = 'none';
                }, 2500);
            });
        }

        if (btnCancelSend && approvalCard) {
            btnCancelSend.addEventListener('click', () => {
                approvalCard.style.display = 'none';
            });
        }

        // Composer Custom Input
        function handleCustomInput() {
            if (!composerInput) return;
            const text = composerInput.value.trim();
            if (!text) return;
            composerInput.value = '';

            if (haloUserText) haloUserText.textContent = `"${text}"`;
            if (haloAssistantText) {
                haloAssistantText.innerHTML = `<p class="assistant-p">Executing "<strong>${text}</strong>" across Notes &amp; macOS Accessibility tree...</p>`;
            }
            if (activityTitleText) activityTitleText.textContent = 'Processing request';
            if (approvalCard) approvalCard.style.display = 'none';

            triggerNotesScan();

            setTimeout(() => {
                if (haloAssistantText) {
                    haloAssistantText.innerHTML = `<p class="assistant-p success" style="color: #38df7b;">✓ Completed "${text}" in Notes.</p>`;
                }
            }, 600);
        }

        if (composerInput) {
            composerInput.addEventListener('keydown', (e) => {
                if (e.key === 'Enter') handleCustomInput();
            });
        }

        if (composerSendBtn) {
            composerSendBtn.addEventListener('click', handleCustomInput);
        }

        // Initial launch demonstration & hash state check
        if (window.location.hash === '#closed' || window.location.search.includes('view=closed')) {
            setPanelState(false);
        } else {
            // Initial scan animation
            setTimeout(() => {
                triggerNotesScan();
            }, 700);
        }
    }
})();
