OS_VARIANT=minbase
DISK_NAME=debian.qcow2
DISK_SIZE=5G

export CC:=gcc-5
DISK_FS=ext4

MODULES-ext4:=mbcache fscrypto jbd2 crc16 crc32c_generic ext4

MODULES:=scsi_mod sd_mod libata ata_piix
MODULES+=$(MODULES-$(DISK_FS))




KERNEL_ENABLE_CONFIG:=ATA_PIIX
KERNEL_SRC=linux
INITRAMFS=initramfs
ROOTFS=rootfs
TOOLS_DIR=tools
TOOLS_SRC=$(TOOLS_DIR)/src
TOOLS_BIN=$(TOOLS_DIR)/bin

TOOLS:=tiny-initramfs ima-evm-utils
TOOLS_APPS:=evmctl init


DISK_SNAPSHOTS=$(shell qemu-img snapshot -l $(DISK_NAME) | sed -E '1,2d;s/^[0-9]+\s+([^ ]+).*/\1/')
ARCH=$(shell uname -m)


#NBD_AVAILABLE=$(filter-out $(shell lsblk -nlpdo NAME /dev/nbd*),$(wildcard /dev/nbd*))
#NBD?=$(lastword $(sort $(NBD_AVAILABLE)))
NBD=4

# TODO: These services are just references
# apt install locales -y; locale-gen pt_BR.UTF-8
# apt install bash-completion -y; . /etc/bash_completion
# apt install vim strace curl -y
# systemctl disable systemd-timesyncd.service
# echo kvm > /etc/hostname



APPEND:=root=/dev/sda rw init=/bin/systemd
APPEND+=console=ttyS0

QEMU:=kvm
QEMU+=-drive format=qcow2,if=ide,file=$(DISK_NAME)
QEMU+=-kernel $(KERNEL_SRC)/arch/$(ARCH)/boot/bzImage
QEMU+=-initrd initramfs.cpio.gz
QEMU+=-append "$(APPEND)"
#QEMU+=-serial mon:stdio
#QEMU+=-nographic
QEMU+=


# Workspace
ws-dir:=/tmp/kernel-ws
mnt-dir:=$(ws-dir)/mnt
ns-dir:=$(ws-dir)/ns

# NBD
nbd-disconnect:=qemu-nbd -d /dev/nbd$(NBD) > /dev/null
nbd-connect:=qemu-nbd -c /dev/nbd$(NBD) $(DISK_NAME)

# Namespaces
sharing-options:=--mount=$(ns-dir)/mnt
unshared:=nsenter $(sharing-options)
umount-rootfs:=$(unshared) umount $(mnt-dir); $(nbd-disconnect)
umount-all:=$(umount-rootfs); umount $(ns-dir)/*; umount $(ns-dir)





$(INITRAMFS):
	# Creating initramfs folder $(INITRAMFS)...
	@mkdir -p $(INITRAMFS)/

$(DISK_NAME):
	# Creating qcow2 $(DISK_NAME) image with $(DISK_SIZE)...
	@qemu-img create -f qcow2 $(DISK_NAME) $(DISK_SIZE)

check-root:
	# Checking if you are root...
	@[ $(USER) = root ] || { echo "ERR: You must be root."; exit 1; }



config-ns: config-ws
	# Setup private namespaces...
	@while umount $(ns-dir)/mnt 2> /dev/null || umount $(ns-dir) 2> /dev/null; do true; done
	@mount --bind --make-rprivate $(ns-dir) $(ns-dir)
	@touch $(ns-dir)/mnt
	@unshare $(sharing-options) true

config-ws: check-root
	# Creating workspace directory structure...
	@mkdir -p $(ws-dir)
	@mkdir -p $(ns-dir)
	@mkdir -p $(mnt-dir)



$(ROOTFS)/:
	# Creating rootfs folder $(ROOTFS)...
	@mkdir -p $(ROOTFS)/

rootfs-dir: $(ROOTFS)/

rootfs-nbd-connect: check-root $(DISK_NAME)
	# Connecting $(DISK_NAME) to /dev/nbd$(NBD)...
	@modprobe nbd max_part=16
	@$(nbd-disconnect)
	@$(nbd-connect)

rootfs-disk: check-root rootfs-nbd-connect
	# Ensuring that disk has a valid filesystem...
	@dumpe2fs -h /dev/nbd$(NBD) > /dev/null 2>&1 || mkfs.ext4 -F /dev/nbd$(NBD) 
	
rootfs-mount: config-ns rootfs-disk
	# Mounting /dev/nbd$(NBD) in $(mnt-dir)
	@$(unshared) mount /dev/nbd$(NBD) $(mnt-dir)

ifneq ($(filter "debootstrap",$(DISK_SNAPSHOTS)),)
rootfs-debootstrap: rootfs-mount
	# Starting debootstrap...
	@$(unshared) debootstrap --variant=$(OS_VARIANT) stretch $(mnt-dir) || { @$(umount-rootfs); exit 1; }

	# Umounting rootfs...
	@$(umount-rootfs)

	# Disconnect /dev/nbd$(NBD)
	@$(nbd-disconnect)

	# Creating snapshot...
	@qemu-img snapshot -c debootstrap $(DISK_NAME)
else
rootfs-debootstrap: check-root
	# Snapshot of debootstrap found! Restoring...
	@qemu-img snapshot -a debootstrap $(DISK_NAME)
endif

rootfs-chroot: rootfs-mount
	# Updating /etc/resolv.conf...
	@$(unshared) cp /etc/resolv.conf $(mnt-dir)/etc/resolv.conf

	# chrooting into the system...
	@$(unshared) chroot $(mnt-dir) || true

	# Umounting all...
	@$(umount-all)

rootfs-update: rootfs-mount rootfs-dir
	# Copying files to $(mnt-dir)...
	cp -rf $(ROOTFS) $(mnt-dir) || true

	# Umounting rootfs...
	@$(umount-rootfs)



$(KERNEL_SRC)/.config:
	$(MAKE) -C $(KERNEL_SRC)/ localmodconfig

$(KERNEL_SRC)/arch/$(ARCH)/boot/bzImage:
	$(MAKE) -C $(KERNEL_SRC)/ bzImage

linux-bzImage: $(KERNEL_SRC)/arch/$(ARCH)/boot/bzImage

linux-config-present: $(KERNEL_SRC)/.config

linux-source:
	[ -d $(KERNEL_SRC)/.git ] || git clone http://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git $(KERNEL_SRC)

linux-configure-enable-$(KERNEL_ENABLE_CONFIG): CONFIG=$(lastword $(subst -, ,$@))
linux-configure-enable-$(KERNEL_ENABLE_CONFIG):
	@cd $(KERNEL_SRC) && scripts/config -e $(CONFIG)

linux-configure-required: linux-configure-enable-$(KERNEL_ENABLE_CONFIG)

linux-configure: linux-source linux-config-present linux-configure-required
	$(MAKE) -C $(KERNEL_SRC)/ menuconfig

linux-modules:
	$(MAKE) -C $(KERNEL_SRC)/ modules

linux-build: linux-source linux-bzImage linux-modules

linux: linux-build




$(INITRAMFS)/: check-root
	mkdir -p $(INITRAMFS)/

$(INITRAMFS)/init: $(TOOLS_BIN)/init
	cp $(TOOLS_BIN)/init $(INITRAMFS)/init
	#cp /bin/busybox $(INITRAMFS)/init

initramfs-init: $(INITRAMFS)/init

initramfs-dir: $(INITRAMFS)/

initramfs-module-$(MODULES): MODULE=$(lastword $(subst -, ,$@)).ko
initramfs-module-$(MODULES): check-root
	# Copying module $(MODULE)...
	@find $(KERNEL_SRC) -name $(MODULE) -exec cp {} $(INITRAMFS)/ \;
	@[ -f $(INITRAMFS)/$(MODULE) ] && echo /$(MODULE) >> $(INITRAMFS)/modules

initramfs-modules-clean:
	# Removing previous modules and related configurations...
	@rm -f $(INITRAMFS)/modules $(INITRAMFS)/*.ko

initramfs-modules:  initramfs-modules-clean initramfs-module-$(MODULES:.ko=)
	# Copying modules to initramfs...
	$(foreach module, $(MODULES),$(call copy-module,$(module)))

initramfs-modules-refresh: linux-modules initramfs-modules

initramfs.cpio.gz: initramfs-init
	# Creating initramfs.img...
	@mkdir -p $(INITRAMFS)/dev $(INITRAMFS)/proc $(INITRAMFS)/target
	@cd $(INITRAMFS) && find . | cpio -o --quiet -R 0:0 -H newc | gzip > ../initramfs.cpio.gz

initramfs-image: initramfs.cpio.gz






$(TOOLS_SRC)/tiny-initramfs/autogen.sh:
	mkdir -p $(TOOLS_SRC)/tiny-initramfs
	git clone https://github.com/chris-se/tiny-initramfs.git $(TOOLS_SRC)/tiny-initramfs

$(TOOLS_SRC)/tiny-initramfs/configure: $(TOOLS_SRC)/tiny-initramfs/autogen.sh
	cd $(TOOLS_SRC)/tiny-initramfs && ./autogen.sh && touch configure

$(TOOLS_SRC)/tiny-initramfs/Makefile: $(TOOLS_SRC)/tiny-initramfs/configure
	cd $(TOOLS_SRC)/tiny-initramfs && ./configure --enable-modules

$(TOOLS_SRC)/tiny-initramfs/tiny_initramfs: $(TOOLS_SRC)/tiny-initramfs/Makefile
	$(MAKE) -C $(TOOLS_SRC)/tiny-initramfs
	touch $(TOOLS_SRC)/tiny-initramfs/tiny_initramfs

$(TOOLS_BIN)/init: $(TOOLS_SRC)/tiny-initramfs/tiny_initramfs
	mkdir -p $(TOOLS_BIN)/
	cp -f $(TOOLS_SRC)/tiny-initramfs/tiny_initramfs $(TOOLS_BIN)/init
	strip $(TOOLS_BIN)/init






$(TOOLS_SRC)/ima-evm-utils/autogen.sh:
	mkdir -p $(TOOLS_SRC)/ima-evm-utils
	git clone http://git.code.sf.net/p/linux-ima/ima-evm-utils $(TOOLS_SRC)/ima-evm-utils

$(TOOLS_SRC)/ima-evm-utils/configure: $(TOOLS_SRC)/ima-evm-utils/autogen.sh
	cd $(TOOLS_SRC)/ima-evm-utils && ./autogen.sh && touch configure

$(TOOLS_SRC)/ima-evm-utils/config.h: $(TOOLS_SRC)/ima-evm-utils/configure
	cd $(TOOLS_SRC)/ima-evm-utils && ./configure

$(TOOLS_SRC)/ima-evm-utils/evmctl.static: $(TOOLS_SRC)/ima-evm-utils/config.h
	cd $(TOOLS_SRC)/ima-evm-utils && ./build-static.sh

$(TOOLS_BIN)/evmctl: $(TOOLS_SRC)/ima-evm-utils/evmctl.static
	mkdir -p $(TOOLS_BIN)/
	cp -f $(TOOLS_SRC)/ima-evm-utils/evmctl.static $(TOOLS_BIN)/evmctl
	strip $(TOOLS_BIN)/evmctl




$(TOOLS_APPS:%=tools-bin-%): tools-bin-%: $(TOOLS_BIN)/%

tools: $(TOOLS_APPS:%=tools-bin-%)





vm-run: #initramfs-image
	@$(QEMU) || true
