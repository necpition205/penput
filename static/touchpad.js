// touchpad.js - Pure functions for touchpad coordinate handling.
// Extracted for testability and SRP. Matches iOS implementation.

/**
 * Input mode: absolute (touch position maps to screen position)
 * or relative (delta movement like a trackpad).
 * @readonly
 * @enum {string}
 */
export const InputMode = {
  ABSOLUTE: "absolute",
  RELATIVE: "relative",
};

/**
 * Compute pad size from container, remote screen, and scale percentage.
 * @param {number} containerWidth - Container width in pixels.
 * @param {number} containerHeight - Container height in pixels.
 * @param {number} remoteW - Remote screen width (0 if unknown).
 * @param {number} remoteH - Remote screen height (0 if unknown).
 * @param {number} padScalePct - Scale percentage (10-100).
 * @returns {{width: number, height: number}} Computed pad size.
 */
export function computePadSize(containerWidth, containerHeight, remoteW, remoteH, padScalePct) {
  const pct = Math.max(10, Math.min(100, padScalePct));
  const base = Math.max(1, Math.min(containerWidth, containerHeight));
  const maxSide = Math.max(1, Math.round((base * pct) / 100));

  const rawAspect = remoteW > 0 && remoteH > 0 ? remoteW / remoteH : 1;
  const aspect = Math.max(1e-6, Math.min(1e6, rawAspect));

  let w = maxSide;
  let h = maxSide;
  if (aspect >= 1) {
    w = maxSide;
    h = Math.max(1, Math.round(maxSide / aspect));
  } else {
    h = maxSide;
    w = Math.max(1, Math.round(maxSide * aspect));
  }

  return { width: w, height: h };
}

/**
 * Map raw touch point to local pad coordinates (clamped to pad bounds).
 * @param {number} touchX - Raw touch X in container coordinates.
 * @param {number} touchY - Raw touch Y in container coordinates.
 * @param {number} containerWidth - Container width.
 * @param {number} containerHeight - Container height.
 * @param {number} padWidth - Pad width.
 * @param {number} padHeight - Pad height.
 * @returns {{x: number, y: number}} Local pad coordinates (0 to padWidth/padHeight).
 */
export function mapToPadCoordinates(touchX, touchY, containerWidth, containerHeight, padWidth, padHeight) {
  const offsetX = Math.max(0, (containerWidth - padWidth) * 0.5);
  const offsetY = Math.max(0, (containerHeight - padHeight) * 0.5);

  const localX = Math.min(padWidth - 0.001, Math.max(0, touchX - offsetX));
  const localY = Math.min(padHeight - 0.001, Math.max(0, touchY - offsetY));

  return { x: localX, y: localY };
}

/**
 * Convert local pad coordinates to screen pixel coordinates (absolute mode).
 * @param {number} localX - Local X in pad coordinates.
 * @param {number} localY - Local Y in pad coordinates.
 * @param {number} padWidth - Pad width.
 * @param {number} padHeight - Pad height.
 * @param {number} clientW - Client viewport width (sent to server).
 * @param {number} clientH - Client viewport height (sent to server).
 * @returns {{x: number, y: number}} Screen pixel coordinates.
 */
export function absoluteToScreen(localX, localY, padWidth, padHeight, clientW, clientH) {
  const relX = Math.max(0, Math.min(1, localX / Math.max(1, padWidth)));
  const relY = Math.max(0, Math.min(1, localY / Math.max(1, padHeight)));

  const pxX = Math.min(clientW - 1, Math.max(0, Math.round(relX * clientW)));
  const pxY = Math.min(clientH - 1, Math.max(0, Math.round(relY * clientH)));

  return { x: pxX, y: pxY };
}

/**
 * State holder for relative mode delta tracking.
 */
export class RelativeTracker {
  constructor(sensitivity = 1.5) {
    this.sensitivity = sensitivity;
    this.lastPoint = null;
    this.accumulatedDeltaX = 0;
    this.accumulatedDeltaY = 0;
    this.currentX = 0;
    this.currentY = 0;
  }

  /**
   * Reset tracking state (call on touch end).
   */
  reset() {
    this.lastPoint = null;
    this.accumulatedDeltaX = 0;
    this.accumulatedDeltaY = 0;
  }

  /**
   * Update position based on delta movement.
   * @param {number} localX - Current local X in pad coordinates.
   * @param {number} localY - Current local Y in pad coordinates.
   * @param {number} padWidth - Pad width.
   * @param {number} padHeight - Pad height.
   * @param {number} clientW - Client viewport width.
   * @param {number} clientH - Client viewport height.
   * @returns {{x: number, y: number}} Updated screen pixel coordinates.
   */
  update(localX, localY, padWidth, padHeight, clientW, clientH) {
    if (this.lastPoint === null) {
      this.lastPoint = { x: localX, y: localY };
      return { x: this.currentX, y: this.currentY };
    }

    const dx = (localX - this.lastPoint.x) * this.sensitivity;
    const dy = (localY - this.lastPoint.y) * this.sensitivity;

    this.accumulatedDeltaX += (dx * clientW) / Math.max(1, padWidth);
    this.accumulatedDeltaY += (dy * clientH) / Math.max(1, padHeight);

    const intDx = Math.trunc(this.accumulatedDeltaX);
    const intDy = Math.trunc(this.accumulatedDeltaY);
    this.accumulatedDeltaX -= intDx;
    this.accumulatedDeltaY -= intDy;

    let newX = this.currentX + intDx;
    let newY = this.currentY + intDy;
    newX = Math.max(0, Math.min(clientW - 1, newX));
    newY = Math.max(0, Math.min(clientH - 1, newY));

    this.currentX = newX;
    this.currentY = newY;
    this.lastPoint = { x: localX, y: localY };

    return { x: this.currentX, y: this.currentY };
  }

  /**
   * Set current position (useful for syncing with absolute mode or initial position).
   * @param {number} x - Screen X.
   * @param {number} y - Screen Y.
   */
  setPosition(x, y) {
    this.currentX = x;
    this.currentY = y;
  }
}
