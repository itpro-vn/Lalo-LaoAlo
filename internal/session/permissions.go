package session

import "errors"

// ErrPermissionDenied is returned when a participant lacks the required permission.
var ErrPermissionDenied = errors.New("permission denied")

// rolePermissions defines the permission matrix per role.
// Spec §10.3: Call Permissions Matrix.
var rolePermissions = map[Role]map[Permission]bool{
	RoleCaller: {
		PermInitiateCall: true,
		PermAcceptCall:   false, // caller doesn't accept their own call
		PermRejectCall:   false,
		PermEndCall:      true,
		PermMuteSelf:     true,
		PermUnmuteSelf:   true,
		PermToggleVideo:  true,
		PermShareScreen:  true,
		PermInvite:       true,
		PermRemoveOther:  true,  // caller can remove in group
		PermMuteOther:    true,  // caller can mute others in group
	},
	RoleCallee: {
		PermInitiateCall: false,
		PermAcceptCall:   true,
		PermRejectCall:   true,
		PermEndCall:      true,
		PermMuteSelf:     true,
		PermUnmuteSelf:   true,
		PermToggleVideo:  true,
		PermShareScreen:  true,
		PermInvite:       false, // callee can't invite in 1:1
		PermRemoveOther:  false,
		PermMuteOther:    false,
	},
	RoleParticipant: {
		PermInitiateCall: false,
		PermAcceptCall:   true,
		PermRejectCall:   true,
		PermEndCall:      true,  // leave call
		PermMuteSelf:     true,
		PermUnmuteSelf:   true,
		PermToggleVideo:  true,
		PermShareScreen:  true,
		PermInvite:       false,
		PermRemoveOther:  false,
		PermMuteOther:    false,
	},
}

// HasPermission checks if a role has the given permission.
func HasPermission(role Role, perm Permission) bool {
	perms, ok := rolePermissions[role]
	if !ok {
		return false
	}
	return perms[perm]
}

// CheckPermission returns an error if the role lacks the permission.
func CheckPermission(role Role, perm Permission) error {
	if !HasPermission(role, perm) {
		return ErrPermissionDenied
	}
	return nil
}

// GroupPermissions extends callee/participant permissions for group calls.
// In group calls, participants can invite others.
func GroupPermissions(role Role, perm Permission) bool {
	// In group calls, callee and participant can also invite
	if perm == PermInvite {
		return true
	}
	return HasPermission(role, perm)
}
