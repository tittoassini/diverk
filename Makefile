android:
	nix-build -A android.frontend -o result-android

	# all:
	#scp -r ubuntu@n1.quid2.org:/home/ubuntu/repo/diverk/result-android /tmp

	# adb install -r android-app-debug.apk 
