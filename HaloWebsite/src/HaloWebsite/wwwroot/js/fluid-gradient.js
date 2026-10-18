/**
 * FluidGradient — GPU-accelerated ChatGPT/macOS style fluid rainbow mesh gradient
 * with interactive cursor & trackpad fluid displacement physics.
 *
 * Implements procedural noise domain warping and harmonic coordinate drifting in WebGL
 * to recreate the soft, flowing, frosted-glass pastel light effect from the ChatGPT macOS app.
 *
 * Configurable properties:
 * - colors: Array of 6 hex colors (defaults to ChatGPT macOS palette)
 * - speed: Flow animation rate (default: 0.65)
 * - intensity: Warp depth & color saturation multiplier (default: 1.0)
 * - opacity: Overall canvas opacity (default: 0.88)
 * - grain: Subtle optical glass dither & grain to prevent color banding (default: 0.024)
 * - interactive: Enable cursor & touch fluid distortion physics (default: true)
 * - paused: Initial paused state (default: false)
 */
(function (global) {
    'use strict';

    // Helper: convert hex to RGB [0-1]
    function hexToRgb(hex) {
        let clean = hex.replace('#', '');
        if (clean.length === 3) {
            clean = clean.split('').map(c => c + c).join('');
        }
        const num = parseInt(clean, 16);
        return [
            ((num >> 16) & 255) / 255,
            ((num >> 8) & 255) / 255,
            (num & 255) / 255
        ];
    }

    const VERTEX_SHADER_SRC = `
        attribute vec2 a_position;
        varying vec2 v_uv;
        void main() {
            v_uv = (a_position + 1.0) * 0.5;
            gl_Position = vec4(a_position, 0.0, 1.0);
        }
    `;

    // Multi-octave smooth simplex / domain-warped procedural liquid shader
    const FRAGMENT_SHADER_SRC = `
        precision highp float;
        varying vec2 v_uv;

        uniform vec2 u_resolution;
        uniform float u_time;
        uniform vec3 u_color0; // Periwinkle
        uniform vec3 u_color1; // Lavender
        uniform vec3 u_color2; // Soft pink
        uniform vec3 u_color3; // Peach
        uniform vec3 u_color4; // Seafoam
        uniform vec3 u_color5; // Sky blue
        uniform float u_speed;
        uniform float u_intensity;
        uniform float u_opacity;
        uniform float u_grain;

        // Pointer fluid physics uniforms
        uniform vec2 u_mouse;           // Aspect-corrected mouse pos [-aspect..aspect, -1..1]
        uniform vec2 u_mouse_velocity;  // Velocity vector of cursor
        uniform float u_mouse_strength; // Damped interaction amplitude (0.0 to 1.0)

        // Simplex-style pseudo noise
        vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        vec3 permute(vec3 x) { return mod289(((x * 34.0) + 1.0) * x); }

        float snoise(vec2 v) {
            const vec4 C = vec4(0.211324865405187,  // (3.0-sqrt(3.0))/6.0
                                0.366025403784439,  // 0.5*(sqrt(3.0)-1.0)
                               -0.577350269189626,  // -1.0 + 2.0 * C.x
                                0.024390243902439); // 1.0 / 41.0
            vec2 i  = floor(v + dot(v, C.yy));
            vec2 x0 = v -   i + dot(i, C.xx);
            vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
            vec4 x12 = x0.xyxy + C.xxzz;
            x12.xy -= i1;
            i = mod289(i);
            vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
            vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
            m = m*m;
            m = m*m;
            vec3 x = 2.0 * fract(p * C.www) - 1.0;
            vec3 h = abs(x) - 0.5;
            vec3 ox = floor(x + 0.5);
            vec3 a0 = x - ox;
            m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
            vec3 g;
            g.x  = a0.x  * x0.x  + h.x  * x0.y;
            g.yz = a0.yz * x12.xz + h.yz * x12.yw;
            return 130.0 * dot(m, g);
        }

        // Fractional Brownian Motion for multi-scale organic fluid
        float fbm(vec2 p) {
            float total = 0.0;
            float amplitude = 0.5;
            for (int i = 0; i < 3; i++) {
                total += snoise(p) * amplitude;
                p = p * 2.02 + vec2(1.3, 0.7);
                amplitude *= 0.5;
            }
            return total;
        }

        void main() {
            // Normalized aspect-corrected coordinate
            vec2 st = gl_FragCoord.xy / u_resolution.xy;
            float aspect = u_resolution.x / u_resolution.y;
            vec2 p = st * 2.0 - 1.0;
            p.x *= aspect;

            // ── Interactive Cursor / Trackpad Fluid Displacement ───────────
            vec2 mouseDiff = p - u_mouse;
            float mouseDist = length(mouseDiff);

            // Smooth Gaussian falloff around cursor
            float mouseInfluence = exp(-mouseDist * 2.5) * u_mouse_strength;

            // Radial displacement (pushes the color field like touching water)
            vec2 mouseDir = (mouseDist > 0.001) ? (mouseDiff / mouseDist) : vec2(0.0);
            vec2 radialPush = mouseDir * mouseInfluence * 0.45;

            // Tangential swirl based on pointer velocity
            vec2 swirlVector = vec2(-u_mouse_velocity.y, u_mouse_velocity.x);
            vec2 swirlPush = swirlVector * mouseInfluence * 0.40;

            // Apply interaction displacement to base coordinates
            p += radialPush + swirlPush;

            // ── Procedural Flow Animation ──────────────────────────────────
            float t = u_time * (0.18 * u_speed);

            // Independent rotating harmonic drift coordinates for multi-directional flow
            vec2 drift1 = vec2(sin(t * 0.7 + 0.2), cos(t * 0.6)) * 0.55;
            vec2 drift2 = vec2(cos(t * 0.5 + 1.8), sin(t * 0.8 + 0.9)) * 0.65;
            vec2 drift3 = vec2(sin(t * 0.9 + 3.1), cos(t * 0.4 + 2.4)) * 0.5;

            // Domain Warping: pass 1
            vec2 q = vec2(
                fbm(p * 0.85 + drift1 + vec2(0.0, 0.0)),
                fbm(p * 0.85 + drift2 + vec2(5.2, 1.3))
            );

            // Domain Warping: pass 2 (liquid folding)
            vec2 r = vec2(
                fbm(p * 0.9 + 1.6 * q + vec2(1.7, 9.2) + drift3),
                fbm(p * 0.9 + 1.6 * q + vec2(8.3, 2.8) - drift1)
            );

            // Flow field intensity
            float f = fbm(p * 0.65 + 1.8 * r * u_intensity);

            // Dynamic color weight blending across 6 pastel anchors
            float w0 = smoothstep(-0.8, 0.2, snoise(p * 0.75 + drift1));
            float w1 = smoothstep(-0.5, 0.5, snoise(p * 0.85 + q * 1.5 + drift2));
            float w2 = smoothstep(-0.6, 0.4, snoise(p * 0.95 + r * 1.8 + drift3));
            float w3 = smoothstep(-0.4, 0.6, f);
            float w4 = smoothstep(-0.7, 0.3, snoise((p + q) * 0.8 - drift1));
            float w5 = smoothstep(-0.5, 0.5, snoise((p + r) * 0.7 + drift2));

            // Layered color blending
            vec3 col = mix(u_color0, u_color5, st.x * 0.5 + 0.25);
            col = mix(col, u_color1, w0 * 0.75);
            col = mix(col, u_color2, w1 * 0.7);
            col = mix(col, u_color3, w2 * 0.6);
            col = mix(col, u_color4, w4 * 0.65);
            col = mix(col, u_color5, w5 * 0.55);

            // Soft center luminescence boost (light diffusing through frosted glass)
            float distFromCenter = length(st - vec2(0.5, 0.45));
            float glow = exp(-distFromCenter * 1.6) * 0.28;
            col += mix(u_color2, u_color3, 0.5) * glow;

            // Interactive luminous bloom under cursor
            float cursorGlow = exp(-mouseDist * 3.5) * u_mouse_strength * 0.32;
            col += mix(u_color1, u_color2, 0.6) * cursorGlow;

            // Anti-banding dither & optical frosted glass texture
            float dither = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
            col += dither * (u_grain * 0.8 + 0.007);

            // Smooth vertical falloff so the gradient dissolves naturally into the page background
            float bottomFade = smoothstep(1.0, 0.55, st.y);
            float alpha = u_opacity * bottomFade;

            gl_FragColor = vec4(col, alpha);
        }
    `;

    class FluidGradient {
        constructor(options = {}) {
            this.canvas = typeof options.canvas === 'string'
                ? document.querySelector(options.canvas)
                : (options.canvas || document.getElementById('gradient-canvas'));

            if (!this.canvas) {
                console.warn('[FluidGradient] No canvas element found');
                return;
            }

            // Configuration
            this.options = Object.assign({
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
                grain: 0.022,
                interactive: true,
                paused: false
            }, options);

            this.gl = null;
            this.program = null;
            this.animationFrameId = null;
            this.startTime = performance.now();
            this.isVisible = true;
            this.isReducedMotion = false;

            // Interaction state (spring & lerp physics)
            this.mouse = { x: 0, y: 0 };
            this.targetMouse = { x: 0, y: 0 };
            this.mouseVelocity = { x: 0, y: 0 };
            this.targetVelocity = { x: 0, y: 0 };
            this.mouseStrength = 0;
            this.targetStrength = 0;
            this.lastPointerTime = performance.now();
            this.lastPointerPos = { x: 0, y: 0 };

            this._checkReducedMotion();
            this._initWebGL();
            this._setupEvents();

            if (!this.options.paused) {
                this.start();
            }
        }

        _checkReducedMotion() {
            try {
                const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
                this.isReducedMotion = mq.matches;
                mq.addEventListener('change', (e) => {
                    this.isReducedMotion = e.matches;
                    if (this.isReducedMotion) {
                        this.renderSingleFrame();
                    } else if (!this.options.paused) {
                        this.start();
                    }
                });
            } catch (e) {
                this.isReducedMotion = false;
            }
        }

        _initWebGL() {
            const gl = this.canvas.getContext('webgl', {
                alpha: true,
                antialias: false,
                depth: false,
                stencil: false,
                powerPreference: 'high-performance',
                preserveDrawingBuffer: false
            }) || this.canvas.getContext('experimental-webgl');

            if (!gl) {
                console.warn('[FluidGradient] WebGL not supported, falling back to CSS gradient');
                this.canvas.classList.add('fallback-gradient');
                return;
            }
            this.gl = gl;

            // Compile shaders
            const vShader = this._compileShader(gl.VERTEX_SHADER, VERTEX_SHADER_SRC);
            const fShader = this._compileShader(gl.FRAGMENT_SHADER, FRAGMENT_SHADER_SRC);
            if (!vShader || !fShader) return;

            const program = gl.createProgram();
            gl.attachShader(program, vShader);
            gl.attachShader(program, fShader);
            gl.linkProgram(program);

            if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
                console.error('[FluidGradient] Link error:', gl.getProgramInfoLog(program));
                return;
            }
            this.program = program;
            gl.useProgram(program);

            // Fullscreen quad buffer
            const vertices = new Float32Array([
                -1.0, -1.0,
                 1.0, -1.0,
                -1.0,  1.0,
                -1.0,  1.0,
                 1.0, -1.0,
                 1.0,  1.0
            ]);

            const buffer = gl.createBuffer();
            gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
            gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.STATIC_DRAW);

            const aPos = gl.getAttribLocation(program, 'a_position');
            gl.enableVertexAttribArray(aPos);
            gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

            // Cache uniform locations
            this.uniforms = {
                u_resolution: gl.getUniformLocation(program, 'u_resolution'),
                u_time: gl.getUniformLocation(program, 'u_time'),
                u_speed: gl.getUniformLocation(program, 'u_speed'),
                u_intensity: gl.getUniformLocation(program, 'u_intensity'),
                u_opacity: gl.getUniformLocation(program, 'u_opacity'),
                u_grain: gl.getUniformLocation(program, 'u_grain'),
                u_color0: gl.getUniformLocation(program, 'u_color0'),
                u_color1: gl.getUniformLocation(program, 'u_color1'),
                u_color2: gl.getUniformLocation(program, 'u_color2'),
                u_color3: gl.getUniformLocation(program, 'u_color3'),
                u_color4: gl.getUniformLocation(program, 'u_color4'),
                u_color5: gl.getUniformLocation(program, 'u_color5'),
                u_mouse: gl.getUniformLocation(program, 'u_mouse'),
                u_mouse_velocity: gl.getUniformLocation(program, 'u_mouse_velocity'),
                u_mouse_strength: gl.getUniformLocation(program, 'u_mouse_strength')
            };

            this._updateColors();
            this.resize();
        }

        _compileShader(type, src) {
            const gl = this.gl;
            const shader = gl.createShader(type);
            gl.shaderSource(shader, src);
            gl.compileShader(shader);
            if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
                console.error('[FluidGradient] Shader compile error:', gl.getShaderInfoLog(shader));
                gl.deleteShader(shader);
                return null;
            }
            return shader;
        }

        _updateColors() {
            if (!this.gl || !this.program) return;
            const gl = this.gl;
            const colors = this.options.colors;
            for (let i = 0; i < 6; i++) {
                const hex = colors[i] || '#6E7BF7';
                const rgb = hexToRgb(hex);
                gl.uniform3f(this.uniforms[`u_color${i}`], rgb[0], rgb[1], rgb[2]);
            }
        }

        _setupEvents() {
            this._onResize = () => this.resize();
            window.addEventListener('resize', this._onResize, { passive: true });

            // Pause rendering when tab is hidden to save battery & CPU/GPU
            this._onVisibilityChange = () => {
                if (document.hidden) {
                    this.pause();
                } else if (!this.options.paused && this.isVisible) {
                    this.start();
                }
            };
            document.addEventListener('visibilitychange', this._onVisibilityChange);

            // Pause rendering when canvas is scrolled out of viewport
            if ('IntersectionObserver' in window) {
                this.observer = new IntersectionObserver((entries) => {
                    entries.forEach(entry => {
                        this.isVisible = entry.isIntersecting;
                        if (this.isVisible && !this.options.paused && !this.isReducedMotion) {
                            this.start();
                        } else {
                            this.pause();
                        }
                    });
                }, { threshold: 0.05 });
                this.observer.observe(this.canvas);
            }

            // Interactive Pointer Events (Mouse, Trackpad, Touch)
            if (this.options.interactive) {
                const handlePointer = (clientX, clientY) => {
                    if (!this.canvas) return;
                    const rect = this.canvas.getBoundingClientRect();
                    const nx = (clientX - rect.left) / rect.width;
                    const ny = 1.0 - (clientY - rect.top) / rect.height; // Invert for WebGL

                    const aspect = this.canvas.width / (this.canvas.height || 1);

                    // Check bounds (with a gentle outer margin)
                    if (nx >= -0.15 && nx <= 1.15 && ny >= -0.15 && ny <= 1.15) {
                        const targetX = (nx * 2.0 - 1.0) * aspect;
                        const targetY = (ny * 2.0 - 1.0);

                        const now = performance.now();
                        const dt = Math.max(1, now - this.lastPointerTime);
                        const dx = (targetX - this.lastPointerPos.x) / (dt * 0.001);
                        const dy = (targetY - this.lastPointerPos.y) / (dt * 0.001);

                        // Clamp velocity
                        const maxV = 2.0;
                        this.targetVelocity.x = Math.max(-maxV, Math.min(maxV, dx * 0.12));
                        this.targetVelocity.y = Math.max(-maxV, Math.min(maxV, dy * 0.12));

                        this.targetMouse.x = targetX;
                        this.targetMouse.y = targetY;
                        this.lastPointerPos.x = targetX;
                        this.lastPointerPos.y = targetY;
                        this.lastPointerTime = now;

                        this.targetStrength = 1.0;
                    } else {
                        this.targetStrength = 0.0;
                    }
                };

                this._onPointerMove = (e) => {
                    handlePointer(e.clientX, e.clientY);
                };

                this._onTouchMove = (e) => {
                    if (e.touches && e.touches[0]) {
                        handlePointer(e.touches[0].clientX, e.touches[0].clientY);
                    }
                };

                this._onPointerLeave = () => {
                    this.targetStrength = 0.0;
                };

                window.addEventListener('pointermove', this._onPointerMove, { passive: true });
                window.addEventListener('touchmove', this._onTouchMove, { passive: true });
                document.addEventListener('pointerleave', this._onPointerLeave, { passive: true });
                window.addEventListener('touchend', this._onPointerLeave, { passive: true });
            }
        }

        resize() {
            if (!this.gl || !this.canvas) return;
            const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
            const rect = this.canvas.getBoundingClientRect();
            const width = Math.max(1, Math.floor(rect.width * dpr));
            const height = Math.max(1, Math.floor(rect.height * dpr));

            if (this.canvas.width !== width || this.canvas.height !== height) {
                this.canvas.width = width;
                this.canvas.height = height;
                this.gl.viewport(0, 0, width, height);
                this.gl.uniform2f(this.uniforms.u_resolution, width, height);
            }

            if (this.isReducedMotion) {
                this.renderSingleFrame();
            }
        }

        render(timestamp) {
            if (!this.gl || !this.program) return;

            const gl = this.gl;
            const elapsed = (timestamp - this.startTime) * 0.001;

            // Smooth spring & physics interpolation for pointer coordinates
            this.mouse.x += (this.targetMouse.x - this.mouse.x) * 0.10;
            this.mouse.y += (this.targetMouse.y - this.mouse.y) * 0.10;

            this.mouseVelocity.x += (this.targetVelocity.x - this.mouseVelocity.x) * 0.08;
            this.mouseVelocity.y += (this.targetVelocity.y - this.mouseVelocity.y) * 0.08;
            this.targetVelocity.x *= 0.94; // Velocity decay
            this.targetVelocity.y *= 0.94;

            // Decay active hover strength gently if pointer remains still
            if (this.targetStrength > 0) {
                const idleTime = performance.now() - this.lastPointerTime;
                if (idleTime > 250) {
                    this.targetStrength = Math.max(0.28, this.targetStrength * 0.96);
                }
            }
            this.mouseStrength += (this.targetStrength - this.mouseStrength) * 0.08;

            gl.uniform1f(this.uniforms.u_time, elapsed);
            gl.uniform1f(this.uniforms.u_speed, this.options.speed);
            gl.uniform1f(this.uniforms.u_intensity, this.options.intensity);
            gl.uniform1f(this.uniforms.u_opacity, this.options.opacity);
            gl.uniform1f(this.uniforms.u_grain, this.options.grain);

            // Pass pointer uniforms
            gl.uniform2f(this.uniforms.u_mouse, this.mouse.x, this.mouse.y);
            gl.uniform2f(this.uniforms.u_mouse_velocity, this.mouseVelocity.x, this.mouseVelocity.y);
            gl.uniform1f(this.uniforms.u_mouse_strength, this.mouseStrength);

            gl.drawArrays(gl.TRIANGLES, 0, 6);

            if (!this.isReducedMotion && !this.options.paused && this.isVisible && !document.hidden) {
                this.animationFrameId = requestAnimationFrame((t) => this.render(t));
            }
        }

        renderSingleFrame() {
            if (this.animationFrameId) {
                cancelAnimationFrame(this.animationFrameId);
                this.animationFrameId = null;
            }
            requestAnimationFrame((t) => this.render(t));
        }

        start() {
            if (this.isReducedMotion) {
                this.renderSingleFrame();
                return;
            }
            if (!this.animationFrameId) {
                this.animationFrameId = requestAnimationFrame((t) => this.render(t));
            }
        }

        pause() {
            if (this.animationFrameId) {
                cancelAnimationFrame(this.animationFrameId);
                this.animationFrameId = null;
            }
        }

        setSpeed(val) {
            this.options.speed = Math.max(0, val);
        }

        setIntensity(val) {
            this.options.intensity = Math.max(0, val);
        }

        setOpacity(val) {
            this.options.opacity = Math.max(0, Math.min(1, val));
        }

        setColors(newColors) {
            if (Array.isArray(newColors) && newColors.length > 0) {
                this.options.colors = newColors;
                this._updateColors();
                if (this.isReducedMotion) this.renderSingleFrame();
            }
        }

        destroy() {
            this.pause();
            if (this.observer) this.observer.disconnect();
            window.removeEventListener('resize', this._onResize);
            document.removeEventListener('visibilitychange', this._onVisibilityChange);
            if (this._onPointerMove) window.removeEventListener('pointermove', this._onPointerMove);
            if (this._onTouchMove) window.removeEventListener('touchmove', this._onTouchMove);
            if (this._onPointerLeave) document.removeEventListener('pointerleave', this._onPointerLeave);
            if (this.gl && this.program) {
                this.gl.deleteProgram(this.program);
            }
            this.gl = null;
        }
    }

    // Expose to window
    global.FluidGradient = FluidGradient;

})(typeof window !== 'undefined' ? window : this);
