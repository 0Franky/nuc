//! Private companion supervisor. Closing Nexus closes stdin; a lost heartbeat
//! also releases input capture rather than leaving an orphaned keyboard grab.
use std::io::{self, BufRead};
use std::process::{Command, Stdio};
#[cfg(windows)]
use std::process::Child;
use std::time::{Duration, Instant};

#[cfg(windows)]
fn guard_child(child: &Child) -> io::Result<impl Drop> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::*;
    struct Job(HANDLE);
    impl Drop for Job { fn drop(&mut self) { unsafe { CloseHandle(self.0); } } }
    unsafe {
        let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if handle.is_null() { return Err(io::Error::last_os_error()); }
        let job = Job(handle);
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(handle, JobObjectExtendedLimitInformation,
            &info as *const _ as _, std::mem::size_of_val(&info) as u32) == 0 ||
            AssignProcessToJobObject(handle, child.as_raw_handle() as _) == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(job)
    }
}

fn run() -> io::Result<()> {
    let mut args = std::env::args_os().skip(1);
    let executable = args.next().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing input-engine executable"))?;
    let mut command = Command::new(executable);
    command.args(args).stdin(Stdio::null());
    #[cfg(windows)] {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    #[cfg(target_os = "linux")] {
        use std::os::unix::process::CommandExt;
        unsafe extern "C" { fn prctl(option: i32, ...) -> i32; fn getppid() -> i32; }
        let parent = std::process::id() as i32;
        unsafe { command.pre_exec(move || {
            if prctl(1, 9, 0, 0, 0) != 0 { return Err(io::Error::last_os_error()); }
            if getppid() != parent { return Err(io::Error::other("input supervisor exited")); }
            Ok(())
        }); }
    }
    let mut child = command.spawn()?;
    #[cfg(windows)]
    let _job = match guard_child(&child) {
        Ok(job) => job,
        Err(error) => { let _ = child.kill(); let _ = child.wait(); return Err(error); }
    };
    let (tx, rx) = std::sync::mpsc::sync_channel(4);
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            if line.is_err() || tx.send(()).is_err() { break; }
        }
    });
    let mut last_heartbeat = Instant::now();
    let result = loop {
        if let Some(status) = child.try_wait()? {
            break if status.success() { Ok(()) } else { Err(io::Error::other(format!("input engine exited: {status}"))) };
        }
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(()) => last_heartbeat = Instant::now(),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break Ok(()),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if last_heartbeat.elapsed() > Duration::from_secs(10) { break Ok(()); }
            }
        }
    };
    if child.try_wait()?.is_none() { let _ = child.kill(); }
    let _ = child.wait();
    result
}

fn main() {
    if let Err(error) = run() { eprintln!("Input supervisor: {error}"); std::process::exit(1); }
}
