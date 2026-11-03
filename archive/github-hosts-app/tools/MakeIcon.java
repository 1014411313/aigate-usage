import javax.imageio.ImageIO;
import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.GradientPaint;
import java.awt.Graphics2D;
import java.awt.Polygon;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.File;

/** 生成启动图标各密度版本到 app/res/mipmap-* 与 icon-1024.png */
public class MakeIcon {

    private static final int SIZE = 1024;

    public static void main(String[] args) throws Exception {
        File resDir = new File(args.length > 0 ? args[0] : "app/res");

        BufferedImage master = new BufferedImage(SIZE, SIZE, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = master.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setPaint(new GradientPaint(0, 0, new Color(0x161B22), SIZE, SIZE, new Color(0x30363D)));
        g.fillRect(0, 0, SIZE, SIZE);

        g.setStroke(new BasicStroke(56, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND));
        g.setColor(new Color(0xF0F6FC));
        g.drawOval(212, 212, 600, 600);

        // 向上的箭头：代表加速
        Polygon head = new Polygon();
        head.addPoint(512, 300);
        head.addPoint(646, 452);
        head.addPoint(378, 452);
        g.fillPolygon(head);

        g.fillRoundRect(452, 430, 120, 300, 36, 36);
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
