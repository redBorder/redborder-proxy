
all: rpm

rpm:
	$(MAKE) -C packaging/rpm

rpmtest:
	$(MAKE) LATEST=`git stash create` -C packaging/rpm

clean:
	rm -rf SOURCES pkgs