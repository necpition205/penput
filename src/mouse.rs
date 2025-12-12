use anyhow::{Context, Result};
use display_info::DisplayInfo;
use enigo::{Coordinate, Enigo, Mouse};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

#[derive(Debug, Copy, Clone)]
struct MoveCmd {
    client_w: u16,
    client_h: u16,
    x: u16,
    y: u16,
}

struct SharedMove {
    latest: Mutex<Option<MoveCmd>>,
    cv: Condvar,
}

/// Mouse controller that maps client coordinates to desktop absolute positions.
#[derive(Clone)]
pub struct MouseController {
    shared: Arc<SharedMove>,
    screen_w: u16,
    screen_h: u16,
}

impl MouseController {
    /// Create a new controller and spawn a dedicated worker thread for mouse moves.
    pub fn new() -> Result<Self> {
        let display = DisplayInfo::all()
            .context("Failed to enumerate displays")?
            .into_iter()
            .next()
            .context("No displays found")?;

        // Keep only the latest move request to avoid backlog (which can cause periodic stutter).
        let shared = Arc::new(SharedMove {
            latest: Mutex::new(None),
            cv: Condvar::new(),
        });
        let worker_shared = shared.clone();

        let screen_w = display.width as f64;
        let screen_h = display.height as f64;
        let screen_w_u16 = (screen_w.round().clamp(1.0, 65535.0)) as u16;
        let screen_h_u16 = (screen_h.round().clamp(1.0, 65535.0)) as u16;

        thread::spawn(move || {
            let enigo_settings = enigo::Settings::default();
            let mut enigo = Enigo::new(&enigo_settings).unwrap();
            loop {
                let cmd = {
                    let mut guard = worker_shared.latest.lock().unwrap();
                    while guard.is_none() {
                        guard = worker_shared.cv.wait(guard).unwrap();
                    }
                    guard.take().unwrap()
                };

                let ratio_x = cmd.x as f64 / cmd.client_w as f64;
                let ratio_y = cmd.y as f64 / cmd.client_h as f64;
                let screen_x = (ratio_x * screen_w) as i32;
                let screen_y = (ratio_y * screen_h) as i32;
                let _ = enigo.move_mouse(screen_x, screen_y, Coordinate::Abs);
            }
        });

        Ok(Self {
            shared,
            screen_w: screen_w_u16,
            screen_h: screen_h_u16,
        })
    }

    pub fn screen_size(&self) -> (u16, u16) {
        (self.screen_w, self.screen_h)
    }

    /// Queue a mouse move; computation is done in the worker thread to avoid blocking async tasks.
    pub fn move_absolute(&self, client_w: u16, client_h: u16, x: u16, y: u16) -> Result<()> {
        if client_w == 0 || client_h == 0 {
            return Ok(());
        }

        // Overwrite the latest value; intermediate points are intentionally dropped.
        let mut guard = self.shared.latest.lock().unwrap();
        *guard = Some(MoveCmd {
            client_w,
            client_h,
            x,
            y,
        });
        drop(guard);
        self.shared.cv.notify_one();
        Ok(())
    }
}
