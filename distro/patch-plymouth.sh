#!/bin/bash
# Run this with: sudo bash patch-plymouth.sh

THEME="/home/kratos/OS/piper-os/distro/work/chroot/usr/share/plymouth/themes/piper-ascii/piper-ascii.script"

cat > "$THEME" << 'PLYSCRIPT'
Window.SetBackgroundTopColor(0.020, 0.020, 0.050);
Window.SetBackgroundBottomColor(0.005, 0.005, 0.020);

cx = Window.GetWidth() / 2;
cy = Window.GetHeight() / 2;

fun txt(s, r, g, b) {
    return Image.Text(s, r, g, b, "Monospace Bold 11");
}

cyan_r=0.0; cyan_g=0.8; cyan_b=1.0;
grn_r=0.0;  grn_g=1.0;  grn_b=0.4;
wht_r=0.9;  wht_g=0.9;  wht_b=0.9;
dim_r=0.4;  dim_g=0.5;  dim_b=0.6;

img_top = txt("+==============================================+", cyan_r, cyan_g, cyan_b);
img_ttl = txt("|         PIPER OS                    v1.1    |", wht_r, wht_g, wht_b);
img_mid = txt("|----------------------------------------------|", cyan_r, cyan_g, cyan_b);

box_w = img_top.GetWidth();
box_x = cx - box_w / 2;
lh    = img_top.GetHeight() + 4;
box_y = cy - 80;

sp_top = Sprite(img_top); sp_top.SetX(box_x); sp_top.SetY(box_y);
sp_ttl = Sprite(img_ttl); sp_ttl.SetX(box_x); sp_ttl.SetY(box_y + lh);
sp_mid = Sprite(img_mid); sp_mid.SetX(box_x); sp_mid.SetY(box_y + lh*2);

labels[0] = "|  [BIOS] Checking pipes...              ";
labels[1] = "|  [CPU ] Initializing core flow...      ";
labels[2] = "|  [MEM ] Pipe RAM detected              ";
labels[3] = "|  [KBD ] Keyboard pipes ready           ";
labels[4] = "|  [IRQ ] Interrupt lines active         ";

for (i = 0; i < 5; i++) {
    li = txt(labels[i], dim_r, dim_g, dim_b);
    oi = txt("OK  |",   grn_r, grn_g, grn_b);
    ls = Sprite(li); ls.SetX(box_x);                    ls.SetY(box_y+lh*(3+i)); ls.SetOpacity(0.0);
    os = Sprite(oi); os.SetX(box_x+li.GetWidth());      os.SetY(box_y+lh*(3+i)); os.SetOpacity(0.0);
    slbl[i]=ls; sok[i]=os;
}

img_mid2 = txt("|----------------------------------------------|", cyan_r, cyan_g, cyan_b);
sp_mid2  = Sprite(img_mid2); sp_mid2.SetX(box_x); sp_mid2.SetY(box_y+lh*8); sp_mid2.SetOpacity(0.0);

pfx_img = txt("|  BOOTING [", dim_r, dim_g, dim_b);
sp_pfx  = Sprite(pfx_img); sp_pfx.SetX(box_x); sp_pfx.SetY(box_y+lh*9); sp_pfx.SetOpacity(0.0);

bar_img = txt("=", grn_r, grn_g, grn_b);
cw = bar_img.GetWidth();
bx = box_x + pfx_img.GetWidth();
for (k=0; k<30; k++) {
    bs=Sprite(bar_img); bs.SetX(bx+k*cw); bs.SetY(box_y+lh*9); bs.SetOpacity(0.0);
    bspr[k]=bs;
}

sfx_img = txt("] 100%   |", wht_r, wht_g, wht_b);
sp_sfx  = Sprite(sfx_img); sp_sfx.SetOpacity(0.0);

img_bot = txt("+==============================================+", cyan_r, cyan_g, cyan_b);
sp_bot  = Sprite(img_bot); sp_bot.SetX(box_x); sp_bot.SetY(box_y+lh*10); sp_bot.SetOpacity(0.0);

dot_sp = Sprite(); dot_sp.SetX(cx-50); dot_sp.SetY(box_y+lh*12);

frame = 0;

fun refresh_callback() {
    frame++;
    for (i=0; i<5; i++) {
        if (frame >= (i+1)*18) { slbl[i].SetOpacity(1.0); sok[i].SetOpacity(1.0); }
    }
    if (frame >= 90) { sp_mid2.SetOpacity(1.0); sp_pfx.SetOpacity(1.0); }
    bf = frame - 90;
    if (bf >= 0) {
        filled = Math.Int(bf/4);
        if (filled > 30) { filled=30; }
        for (k=0; k<filled; k++) { bspr[k].SetOpacity(1.0); }
    }
    if (frame >= 90+120) {
        sp_sfx.SetX(bx+30*cw); sp_sfx.SetY(box_y+lh*9); sp_sfx.SetOpacity(1.0);
        sp_bot.SetOpacity(1.0);
    }
    local.mod = Math.Int(frame/10) % 4;
    local.d = "";
    for (j=0; j<local.mod; j++) { local.d = local.d + "."; }
    local.di = Image.Text("Booting" + local.d, dim_r, dim_g, dim_b, "Monospace 10");
    dot_sp.SetImage(local.di);
}

Plymouth.SetRefreshFunction(refresh_callback);
PLYSCRIPT

echo "[OK] Plymouth script patched."

# Repack squashfs with updated chroot
CHROOT="/home/kratos/OS/piper-os/distro/work/chroot"
ISO_DIR="/home/kratos/OS/piper-os/distro/work/iso"
OUTPUT="/home/kratos/OS/piper-os/distro/piper-os-live.iso"

echo "[..] Repacking squashfs (this takes a few minutes)..."
mksquashfs "$CHROOT" "$ISO_DIR/casper/filesystem.squashfs" \
    -comp xz -Xbcj x86 -b 1M -no-duplicates -no-recovery \
    -e "$CHROOT/boot/vmlinuz-*" \
    -e "$CHROOT/boot/initrd.img-*" \
    -noappend

echo "[..] Rebuilding ISO..."
grub-mkrescue -o "$OUTPUT" "$ISO_DIR" -- -volid "PIPER_OS"

echo "[DONE] New ISO: $OUTPUT"
echo "Run: qemu-system-x86_64 -m 4G -cdrom $OUTPUT -enable-kvm -net nic -net user"
