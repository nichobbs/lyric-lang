/* Checks, against AccessKit's own header, the offsets in `accesskit_action_request` and the
 * constants that lyric-access/platform/src/access.l reads by hand (the request carries a C union,
 * which `lyric bindgen` does not bind).  Compiled (not run) by scripts/ci/ui-native-e2e.sh:
 * a mismatch is a compile error. */
#include <accesskit.h>
#include <stddef.h>

#define CHECK(name, cond) _Static_assert(cond, name)

CHECK("action is the first byte", offsetof(accesskit_action_request, action) == 0);
CHECK("action is one byte", sizeof(accesskit_action) == 1);
CHECK("target node", offsetof(accesskit_action_request, target_node) == 24);
CHECK("node id is 64 bits", sizeof(accesskit_node_id) == 8);
CHECK("data", offsetof(accesskit_action_request, data) == 32);
CHECK("data has_value", offsetof(accesskit_opt_action_data, has_value) == 0);
CHECK("data tag", offsetof(accesskit_opt_action_data, value) + offsetof(accesskit_action_data, tag) == 8);
CHECK("data tag is 32 bits", sizeof(accesskit_action_data_Tag) == 4);
CHECK("data value", offsetof(accesskit_opt_action_data, value) + offsetof(accesskit_action_data, value) == 16);
CHECK("value data tag", ACCESSKIT_ACTION_DATA_VALUE == 1);
