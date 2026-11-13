//! Keep the daemon reachable from normal-privilege clients when it runs
//! elevated on Windows.
//!
//! The daemon's named pipes get the default pipe security descriptor: full
//! control for SYSTEM, Administrators and the pipe's owner, read-only for
//! everyone else. The owner is the creating token's default owner, which for an
//! elevated ("Run as administrator") token is the Administrators group. A
//! non-elevated client of the same user only holds that group as deny-only, so
//! it fails with `ERROR_ACCESS_DENIED` and its checkpoints are lost.
//!
//! Making the user the default owner of objects the daemon creates gives the
//! user's SID full control of the pipes, which both elevated and non-elevated
//! clients carry. An elevated daemon is then as reachable as a normal one, and
//! the daemon never has to be started with another process's token or parent,
//! which endpoint security products treat as an attack.

use std::ffi::c_void;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::Security::{
    GetTokenInformation, SetTokenInformation, TOKEN_ADJUST_DEFAULT, TOKEN_OWNER, TOKEN_QUERY,
    TOKEN_USER, TokenOwner, TokenUser,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

/// Room for a `TOKEN_USER` followed by the largest possible SID
/// (`SECURITY_MAX_SID_SIZE` is 68 bytes), aligned for the struct.
#[repr(C, align(8))]
struct TokenUserBuffer([u8; 128]);

/// Make the current user (instead of the Administrators group) the owner of
/// every object this process creates from now on. A no-op for a non-elevated
/// process, whose default owner already is the user.
pub fn own_new_objects_as_current_user() -> Result<(), String> {
    let mut token: HANDLE = std::ptr::null_mut();
    if unsafe {
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_QUERY | TOKEN_ADJUST_DEFAULT,
            &mut token,
        )
    } == 0
    {
        return Err(last_error("OpenProcessToken"));
    }
    let result = set_token_owner_to_token_user(token);
    unsafe {
        CloseHandle(token);
    }
    result
}

fn set_token_owner_to_token_user(token: HANDLE) -> Result<(), String> {
    let mut buffer = TokenUserBuffer([0; 128]);
    let mut returned: u32 = 0;
    if unsafe {
        GetTokenInformation(
            token,
            TokenUser,
            buffer.0.as_mut_ptr() as *mut c_void,
            buffer.0.len() as u32,
            &mut returned,
        )
    } == 0
    {
        return Err(last_error("GetTokenInformation(TokenUser)"));
    }
    // SAFETY: on success the buffer starts with an initialized TOKEN_USER whose
    // SID pointer refers into the same buffer, which outlives this call.
    let user = unsafe { &*(buffer.0.as_ptr() as *const TOKEN_USER) };
    let owner = TOKEN_OWNER {
        Owner: user.User.Sid,
    };
    if unsafe {
        SetTokenInformation(
            token,
            TokenOwner,
            &owner as *const TOKEN_OWNER as *const c_void,
            std::mem::size_of::<TOKEN_OWNER>() as u32,
        )
    } == 0
    {
        return Err(last_error("SetTokenInformation(TokenOwner)"));
    }
    Ok(())
}

fn last_error(what: &str) -> String {
    format!("{} failed: {}", what, std::io::Error::last_os_error())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::{INVALID_HANDLE_VALUE, LocalFree};
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, GetSecurityInfo, SE_KERNEL_OBJECT,
    };
    use windows_sys::Win32::Security::{OWNER_SECURITY_INFORMATION, PSID};
    use windows_sys::Win32::System::Pipes::CreateNamedPipeW;

    const PIPE_ACCESS_DUPLEX: u32 = 0x0000_0003;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x0008_0000;

    fn sid_string(sid: PSID) -> String {
        let mut wide: *mut u16 = std::ptr::null_mut();
        assert_ne!(unsafe { ConvertSidToStringSidW(sid, &mut wide) }, 0);
        let len = (0..).take_while(|&i| unsafe { *wide.add(i) } != 0).count();
        let text = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(wide, len) });
        unsafe {
            LocalFree(wide as *mut c_void);
        }
        text
    }

    fn current_user_sid() -> String {
        let mut token: HANDLE = std::ptr::null_mut();
        assert_ne!(
            unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
            0
        );
        let mut buffer = TokenUserBuffer([0; 128]);
        let mut returned: u32 = 0;
        assert_ne!(
            unsafe {
                GetTokenInformation(
                    token,
                    TokenUser,
                    buffer.0.as_mut_ptr() as *mut c_void,
                    buffer.0.len() as u32,
                    &mut returned,
                )
            },
            0
        );
        unsafe {
            CloseHandle(token);
        }
        sid_string(
            unsafe { &*(buffer.0.as_ptr() as *const TOKEN_USER) }
                .User
                .Sid,
        )
    }

    /// Owner SID of a pipe created the way the daemon creates its pipes: with
    /// no explicit security attributes.
    fn owner_of_new_default_pipe() -> String {
        let name: Vec<u16> = std::ffi::OsStr::new(&format!(
            r"\\.\pipe\git-ai-test-owner-{}",
            std::process::id()
        ))
        .encode_wide()
        .chain(Some(0))
        .collect();
        let pipe = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                0,
                1,
                0,
                0,
                0,
                std::ptr::null(),
            )
        };
        assert_ne!(pipe, INVALID_HANDLE_VALUE);

        let mut owner: PSID = std::ptr::null_mut();
        let mut descriptor: *mut c_void = std::ptr::null_mut();
        let status = unsafe {
            GetSecurityInfo(
                pipe,
                SE_KERNEL_OBJECT,
                OWNER_SECURITY_INFORMATION,
                &mut owner,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor,
            )
        };
        assert_eq!(status, 0);
        let owner = sid_string(owner);
        unsafe {
            LocalFree(descriptor);
            CloseHandle(pipe);
        }
        owner
    }

    /// The pipe owner gets full control of the pipe, so the owner must be the
    /// user (a SID non-elevated clients hold) even when the daemon is elevated.
    #[test]
    fn pipes_created_after_the_call_are_owned_by_the_user() {
        own_new_objects_as_current_user().unwrap();
        assert_eq!(owner_of_new_default_pipe(), current_user_sid());
    }
}
