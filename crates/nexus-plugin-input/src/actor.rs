use async_trait::async_trait;
use nexus_actor_system::{EventBus, NexusActor, NexusCommand};
use nexus_protocol::{InputPayload, NexusPacket, PacketPayload};
use nexus_types::{DeviceId, NexusResult, ScreenGeometry};

use crate::ballistics::{GyroLaserFilter, TouchpadBallistics};
use crate::injector::NativeInputInjector;
use crate::universal_control::UniversalControlEngine;

/// Input Plugin Actor: Handles incoming touch/keyboard/gyro streams and injects into OS
#[derive(Clone)]
pub struct InputPluginActor {
    pub device_id: DeviceId,
    pub ballistics: TouchpadBallistics,
    pub gyro_filter: GyroLaserFilter,
    pub universal_control: UniversalControlEngine,
}

impl InputPluginActor {
    pub fn new(device_id: DeviceId) -> Self {
        Self {
            device_id,
            ballistics: TouchpadBallistics::default(),
            gyro_filter: GyroLaserFilter::default(),
            universal_control: UniversalControlEngine::new(ScreenGeometry::default()),
        }
    }

    /// Emits a mouse move event to a remote target peer
    pub async fn emit_mouse_move(
        &self,
        bus: &EventBus,
        target_peer: DeviceId,
        dx: i16,
        dy: i16,
    ) -> NexusResult<()> {
        let payload = PacketPayload::Input(InputPayload::MouseMoveRelative { dx, dy });
        let packet = NexusPacket::new(self.device_id, payload).with_target(target_peer);

        bus.send_command(NexusCommand::SendPacket {
            target: target_peer,
            packet,
        })
        .await?;

        Ok(())
    }

    /// Processes an incoming input payload from a remote peer
    pub fn handle_remote_input(&mut self, payload: InputPayload) -> NexusResult<()> {
        match payload {
            InputPayload::MouseMoveRelative { dx, dy } => {
                let (scaled_dx, scaled_dy) = self.ballistics.calculate_delta(dx as f32, dy as f32);
                NativeInputInjector::inject_mouse_move_relative(scaled_dx, scaled_dy)?;
            }
            InputPayload::MouseButton { button, is_down } => {
                NativeInputInjector::inject_mouse_button(button, is_down)?;
            }
            InputPayload::GyroLaserPointer {
                pitch_delta,
                yaw_delta,
            } => {
                let (smooth_x, smooth_y) = self.gyro_filter.update(pitch_delta, yaw_delta);
                let dx = (smooth_x * 20.0).round() as i32;
                let dy = (smooth_y * 20.0).round() as i32;
                NativeInputInjector::inject_mouse_move_relative(dx, dy)?;
            }
            _ => {}
        }
        Ok(())
    }
}

#[async_trait]
impl NexusActor for InputPluginActor {
    fn name(&self) -> &'static str {
        "nexus-plugin-input"
    }

    async fn run(&mut self, _bus: EventBus) -> NexusResult<()> {
        // Keeps actor loop alive
        tokio::time::sleep(tokio::time::Duration::from_secs(3600 * 24)).await;
        Ok(())
    }
}
