#
#
#

PKG += 		-pkg lwt
PKG += 		-pkg xen-api-client.lwt
PKG += 		-pkg ezxmlm
PKG += 		-pkg ssl
PKG += 		-pkg lwt.ssl
PKG += 		-pkg lwt.unix

TAG += 		-tag annot
TAG += 		-tag bin_annot

OCB_FLAGS 	= -use-ocamlfind $(TAG) -I tests -I scripts $(PKG)
OCB 		= ocamlbuild $(OCB_FLAGS)

all:
		$(OCB) test_quicktest.native

clean:
		$(OCB) -clean
