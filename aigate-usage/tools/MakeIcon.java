import javax.imageio.ImageIO;
import java.awt.*;
import java.awt.geom.Arc2D;
import java.awt.image.BufferedImage;
import java.io.File;

/** 生成启动图标各密度版本，输出到 app/res/mipmap-* 与 aigate-usage/icon-1024.png */
public class MakeIcon {

    private static final int SIZE = 1024;

    public static void main(String[] args) throws Exception {
        File resDir = new File(args.length > 0 ? args[0] : "app/res");

        BufferedImage master = new BufferedImage(SIZE, SIZE, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = master.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setPaint(new GradientPaint(0, 0, new Color(0x4F46E5), SIZE, SIZE, new Color(0x7C3AED)));
        g.fillRect(0, 0, SIZE, SIZE);

        g.setColor(new Color(255, 255, 255, 235));
        int barW = 118, gap = 46, baseY = 800, radius = 40;
        int[] heights = {200, 330, 470};
        int x = (SIZE - (heights.length * barW + (heights.length - 1) * gap)) / 2;
        for (int h : heights) {
            g.fillRoundRect(x, baseY - h, barW, h, radius, radius);
            x += barW + gap;
        }

        g.setStroke(new BasicStroke(34, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND));
        g.setColor(new Color(255, 255, 255, 205));
        g.draw(new Arc2D.Double(270, 88, 500, 500, 22, 136, Arc2D.OPEN));
        g.dispose();

        int[] sizes = {48, 72, 96, 144, 192};
        String[] densities = {"mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"};
        for (int i = 0; i < sizes.length; i++) {
            File dir = new File(resDir, "mipmap-" + densities[i]);
            if (!dir.mkdirs() && !dir.isDirectory()) throw new IllegalStateException("无法创建 " + dir);
            BufferedImage scaled = new BufferedImage(sizes[i], sizes[i], BufferedImage.TYPE_INT_ARGB);
            Graphics2D sg = scaled.createGraphics();
            sg.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
            sg.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            sg.drawImage(master, 0, 0, sizes[i], sizes[i], null);
            sg.dispose();
            ImageIO.write(scaled, "png", new File(dir, "ic_launcher.png"));
        }

        ImageIO.write(master, "png", new File(resDir.getParentFile(), "icon-1024.png"));
        System.out.println("图标已生成：" + resDir.getAbsolutePath());
    }
}
