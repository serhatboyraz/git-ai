//! Start the background daemon without administrator rights on Windows.
//!
//! The daemon's named pipes are created with the default security descriptor of
//! the token that creates them. When an elevated ("Run as administrator")
//! client spawns the daemon, the pipes only admit elevated callers, so every
//! normal-privilege client (IDE extensions, agent hooks) fails with
//! `ERROR_ACCESS_DENIED` and its checkpoints are lost.
//!
//! A daemon running with the user's normal token, on the other hand, is
//! reachable from both elevated and non-elevated clients, because both carry
//! the user's SID. So when an elevated client has to spawn the daemon, it
//! creates the process with the interactive desktop shell (explorer.exe) as its
//! parent (`PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`). A process created that way
//! inherits the parent's token, which is not elevated. Unlike
//! `CreateProcessWithTokenW`/`CreateProcessAsUserW`, this needs no special
//! privilege, only `PROCESS_CREATE_PROCESS` on the shell process, which the
//! user owns.

use std::ffi::{OsStr, OsString, c_void};
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, HANDLE};
use windows_sys::Win32::Security::{
    GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation,
};
use windows_sys::Win32::System::Threading::{
    CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT, CreateProcessW,
    DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, GetCurrentProcess,
    InitializeProcThreadAttributeList, OpenProcess, OpenProcessToken,
    PROC_THREAD_ATTRIBUTE_PARENT_PROCESS, PROCESS_CREATE_PROCESS, PROCESS_INFORMATION,
    PROCESS_QUERY_LIMITED_INFORMATION, STARTF_USESHOWWINDOW, STARTUPINFOEXW, STARTUPINFOW,
    UpdateProcThreadAttribute,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetShellWindow, GetWindowThreadProcessId, SW_HIDE,
};

struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

fn last_error(what: &str) -> String {
    let code = unsafe { GetLastError() };
    format!(
        "{} failed: {}",
        what,
        std::io::Error::from_raw_os_error(code as i32)
    )
}

/// Whether a process token is elevated (`TokenElevation`).
///
/// Deliberately not `TokenElevationType == Full`: a process can hold a full
/// administrator token that is not the elevated half of a UAC split token
/// (elevation type `Default`, e.g. when launched through some elevation
/// tools). Its pipes reject non-elevated clients all the same.
fn token_is_elevated(token: HANDLE) -> bool {
    let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
    let mut returned: u32 = 0;
    let ok = unsafe {
        GetTokenInformation(
            token,
            TokenElevation,
            &mut elevation as *mut TOKEN_ELEVATION as *mut c_void,
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut returned,
        )
    };
    ok != 0 && elevation.TokenIsElevated != 0
}

fn process_is_elevated(process: HANDLE) -> Option<bool> {
    let mut token: HANDLE = std::ptr::null_mut();
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return None;
    }
    let token = OwnedHandle(token);
    Some(token_is_elevated(token.0))
}

/// True when the current process runs with an elevated token.
pub(super) fn current_process_is_elevated() -> bool {
    process_is_elevated(unsafe { GetCurrentProcess() }).unwrap_or(false)
}

/// Open the process that owns the desktop shell window (explorer.exe) with the
/// rights needed to use it as a parent. Fails when there is no interactive
/// shell (services, SSH sessions) or the shell is itself elevated (UAC off),
/// in which case re-parenting would gain nothing.
fn open_unelevated_shell_process() -> Result<OwnedHandle, String> {
    let shell_window = unsafe { GetShellWindow() };
    if shell_window.is_null() {
        return Err("no desktop shell window (non-interactive session)".to_string());
    }

    let mut shell_pid: u32 = 0;
    unsafe {
        GetWindowThreadProcessId(shell_window, &mut shell_pid);
    }
    if shell_pid == 0 {
        return Err(last_error("GetWindowThreadProcessId"));
    }

    let process = unsafe {
        OpenProcess(
            PROCESS_CREATE_PROCESS | PROCESS_QUERY_LIMITED_INFORMATION,
            0,
            shell_pid,
        )
    };
    if process.is_null() {
        return Err(last_error("OpenProcess(desktop shell)"));
    }
    let process = OwnedHandle(process);

    if process_is_elevated(process.0).unwrap_or(true) {
        return Err("the desktop shell is itself elevated".to_string());
    }
    Ok(process)
}

/// Proc-thread attribute list holding a single `PARENT_PROCESS` attribute.
struct ParentProcessAttribute {
    buffer: Vec<usize>,
    // `UpdateProcThreadAttribute` stores a pointer to this value; it must stay
    // at a stable address until `CreateProcessW` returns.
    _parent: Box<HANDLE>,
}

impl ParentProcessAttribute {
    fn new(parent: HANDLE) -> Result<Self, String> {
        let mut size: usize = 0;
        unsafe {
            // First call only reports the required size (and fails by design).
            InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut size);
        }
        if size == 0 {
            return Err(last_error("InitializeProcThreadAttributeList(size)"));
        }
        let mut buffer = vec![0usize; size.div_ceil(std::mem::size_of::<usize>())];
        if unsafe { InitializeProcThreadAttributeList(buffer.as_mut_ptr().cast(), 1, 0, &mut size) }
            == 0
        {
            return Err(last_error("InitializeProcThreadAttributeList"));
        }

        let parent = Box::new(parent);
        let ok = unsafe {
            UpdateProcThreadAttribute(
                buffer.as_mut_ptr().cast(),
                0,
                PROC_THREAD_ATTRIBUTE_PARENT_PROCESS as usize,
                (&*parent as *const HANDLE).cast(),
                std::mem::size_of::<HANDLE>(),
                std::ptr::null_mut(),
                std::ptr::null(),
            )
        };
        let attribute = ParentProcessAttribute {
            buffer,
            _parent: parent,
        };
        if ok == 0 {
            return Err(last_error("UpdateProcThreadAttribute(PARENT_PROCESS)"));
        }
        Ok(attribute)
    }

    fn as_ptr(&mut self) -> *mut c_void {
        self.buffer.as_mut_ptr().cast()
    }
}

impl Drop for ParentProcessAttribute {
    fn drop(&mut self) {
        unsafe { DeleteProcThreadAttributeList(self.buffer.as_mut_ptr().cast()) };
    }
}

/// Spawn `exe args...` in `cwd` as a child of the (non-elevated) desktop
/// shell, so it runs with the user's normal token.
///
/// `env` is the complete environment for the child. Callers should fall back
/// to a normal spawn when this fails.
pub(super) fn spawn_as_shell_child(
    exe: &Path,
    args: &[&str],
    cwd: &Path,
    env: impl IntoIterator<Item = (OsString, OsString)>,
) -> Result<(), String> {
    let shell = open_unelevated_shell_process()?;
    let mut attribute = ParentProcessAttribute::new(shell.0)?;

    let application = to_wide_nul(exe.as_os_str());
    let mut command_line = to_wide_nul(&command_line(exe, args));
    let environment = environment_block(env);
    let current_dir = to_wide_nul(cwd.as_os_str());

    let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
    startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESHOWWINDOW;
    startup.StartupInfo.wShowWindow = SW_HIDE as u16;
    startup.lpAttributeList = attribute.as_ptr();
    let mut process: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

    let ok = unsafe {
        CreateProcessW(
            application.as_ptr(),
            command_line.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            CREATE_NO_WINDOW
                | CREATE_NEW_PROCESS_GROUP
                | CREATE_UNICODE_ENVIRONMENT
                | EXTENDED_STARTUPINFO_PRESENT,
            environment.as_ptr() as *const c_void,
            current_dir.as_ptr(),
            &startup as *const STARTUPINFOEXW as *const STARTUPINFOW,
            &mut process,
        )
    };
    if ok == 0 {
        return Err(last_error("CreateProcessW(parent = desktop shell)"));
    }
    drop(OwnedHandle(process.hThread));
    drop(OwnedHandle(process.hProcess));
    Ok(())
}

fn to_wide_nul(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

/// `"<exe>" arg1 arg2`. The executable path is always quoted (Windows paths
/// cannot contain `"`); the fixed daemon arguments need no quoting.
fn command_line(exe: &Path, args: &[&str]) -> OsString {
    let mut line = OsString::from("\"");
    line.push(exe.as_os_str());
    line.push("\"");
    for arg in args {
        line.push(" ");
        line.push(arg);
    }
    line
}

/// Build a `CREATE_UNICODE_ENVIRONMENT` block: `NAME=value\0...\0\0`, sorted
/// case-insensitively by name as Windows expects.
fn environment_block(env: impl IntoIterator<Item = (OsString, OsString)>) -> Vec<u16> {
    let mut vars: Vec<(OsString, OsString)> = env.into_iter().collect();
    vars.sort_by_key(|(name, _)| name.to_string_lossy().to_uppercase());

    let mut block = Vec::new();
    for (name, value) in vars {
        block.extend(name.encode_wide());
        block.push(u16::from(b'='));
        block.extend(value.encode_wide());
        block.push(0);
    }
    if block.is_empty() {
        block.push(0);
    }
    block.push(0);
    block
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wide(s: &str) -> Vec<u16> {
        OsStr::new(s).encode_wide().collect()
    }

    #[test]
    fn command_line_quotes_executable_path() {
        let line = command_line(
            Path::new(r"C:\Users\some user\.git-ai\bin\git-ai.exe"),
            &["bg", "run"],
        );
        assert_eq!(
            line,
            OsString::from(r#""C:\Users\some user\.git-ai\bin\git-ai.exe" bg run"#)
        );
    }

    #[test]
    fn environment_block_is_sorted_and_double_nul_terminated() {
        let block = environment_block(vec![
            (OsString::from("path"), OsString::from(r"C:\bin")),
            (OsString::from("APPDATA"), OsString::from(r"C:\data")),
        ]);
        let mut expected = wide(r"APPDATA=C:\data");
        expected.push(0);
        expected.extend(wide(r"path=C:\bin"));
        expected.push(0);
        expected.push(0);
        assert_eq!(block, expected);
    }

    #[test]
    fn empty_environment_block_is_two_nuls() {
        assert_eq!(environment_block(Vec::new()), vec![0, 0]);
    }
}
