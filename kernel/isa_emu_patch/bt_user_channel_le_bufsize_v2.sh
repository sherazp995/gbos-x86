#!/bin/sh
# ThinkPad X13 Gen 2 AMD (Qualcomm WCN6855 Bluetooth, USB 0489:e0d0): the controller lists "LE Read Buffer Size v2" (supported commands
# octet 41 bit 5) but its reply to it is malformed. Google's Bluetooth stack (gd, through the desktop HCI HAL on the HCI user channel)
# sends it whenever the bit is set and aborts on the reply ("le_read_buffer_size_v2_handler: Complete view is invalid"), so Bluetooth
# never turns on. Linux itself only sends v2 when the controller also reports LE ISO support (iso_capable(), hci_sync.c).
# Apply the same rule on the user channel: in the Read Local Supported Commands reply going to userspace, clear the v2 bit when the
# controller has no ISO feature, so gd falls back to LE Read Buffer Size v1. Only that bit of that reply changes, only on the user channel.
# bluetooth.ko is a module (CONFIG_BT=m): the kernel build's modules carry the change. Idempotent.
set -e
cd /build/src/net/bluetooth
grep -q 'gbos: LE Read Buffer Size v2' hci_core.c && { echo already; exit 0; }
python3 - hci_core.c <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()

def sub(old, new):
    global s
    assert s.count(old) == 1, "anchor mismatch: " + old
    s = s.replace(old, new)

sub("""static void hci_rx_work(struct work_struct *work)
{""", """/* gbos: LE Read Buffer Size v2 on the user channel. A controller that lists the command without LE ISO support (WCN6855,
 * 0489:e0d0) answers it malformed and Android's stack aborts; Linux only uses v2 with ISO, so hide the bit from userspace too.
 */
static void hci_user_channel_fix_commands(struct hci_dev *hdev, struct sk_buff *skb)
{
	const size_t octet41 = HCI_EVENT_HDR_SIZE + sizeof(struct hci_ev_cmd_complete) + 1 + 41;

	if (hci_skb_pkt_type(skb) != HCI_EVENT_PKT || skb->len <= octet41 ||
	    skb->data[0] != HCI_EV_CMD_COMPLETE ||
	    get_unaligned_le16(skb->data + HCI_EVENT_HDR_SIZE + 1) != HCI_OP_READ_LOCAL_COMMANDS ||
	    iso_capable(hdev) || !(skb->data[octet41] & 0x20))
		return;
	skb->data[octet41] &= ~0x20;
	bt_dev_info(hdev, "hiding LE Read Buffer Size v2 from the user channel (no LE ISO support)");
}

static void hci_rx_work(struct work_struct *work)
{""")

sub("""		if (atomic_read(&hdev->promisc)) {
			/* Send copy to the sockets */
			hci_send_to_sock(hdev, skb);
		}
""", """		if (hci_dev_test_flag(hdev, HCI_USER_CHANNEL))
			hci_user_channel_fix_commands(hdev, skb);

		if (atomic_read(&hdev->promisc)) {
			/* Send copy to the sockets */
			hci_send_to_sock(hdev, skb);
		}
""")
open(p, 'w').write(s)
PYEOF
grep -n 'hci_user_channel_fix_commands' hci_core.c
