use anyhow::{Context, Result};
use display_info::DisplayInfo;
use enigo::{Enigo, MouseControllable};
use std::sync::Mutex;

/// Mouse controller that maps client coordinates to desktop absolute positions.
pub struct MouseController {
    enigo: Mutex<Enigo>,
    screen_width: i32,
    screen_height: i32,
}

impl MouseController {
    /// Create a new controller and capture the primary screen size.
    pub fn new() -> Result<Self> {
        let enigo = Enigo::new();
        let display = DisplayInfo::all()
            .context("Failed to enumerate displays")?
            .into_iter()
            .next()
            .context("No displays found")?;

        Ok(Self {
            enigo: Mutex::new(enigo),
            screen_width: display.width as i32,
            screen_height: display.height as i32,
        })
    }

    /// Move the mouse to the absolute position mapped from client touch input.
    pub fn move_absolute(&self, client_w: u16, client_h: u16, x: u16, y: u16) -> Result<()> {
        let ratio_x = x as f64 / client_w as f64;
        let ratio_y = y as f64 / client_h as f64;

        let screen_x = (ratio_x * self.screen_width as f64) as i32;
        let screen_y = (ratio_y * self.screen_height as f64) as i32;

        let mut enigo = self.enigo.lock().unwrap();
        enigo.mouse_move_to(screen_x, screen_y);
        Ok(())
    }
}
