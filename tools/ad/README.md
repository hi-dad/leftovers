The 37-second ad (images/leftovers.gif). Open ad.html in a browser to watch it live.

To re-render:

    DUR=37 node capture.mjs ad.html /tmp/lo-frames 15
    ffmpeg -framerate 15 -i /tmp/lo-frames/f%04d.png -vf "fps=12,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" ../../images/leftovers.gif

For a review copy with a timer in the corner: `Q='&stamp' node capture.mjs ...`.
