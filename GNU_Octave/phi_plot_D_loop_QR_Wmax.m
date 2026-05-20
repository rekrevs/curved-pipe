%NTB 2024
%Read and plot data from Schubert_Fortran66_1972.f
%

clc
clear all
close all

%default
graphics_toolkit ("qt")

%graphics_toolkit ("gnuplot")
%graphics_toolkit ("fltk")

%Figure settings (Nils's blindeskrift)
set(0,'defaultlinelinewidth',2);
set(0,'defaultaxeslinewidth',2);
set(0,'defaulttextfontsize',14);
set(0,'defaultaxesfontsize',14);

addpath('C:\Users\nilsba\OneDrive - RISE\NTB\projects\Non-funded\Fortran66\Schubert_Fortran66_1972')

%Dean
D_plot=0:10:5000;
K_plot=(D_plot./4).^2;
flux_plot=1.-((K_plot./576).^2)*0.03058+((K_plot./576).^4)*0.01195;

%McConalogue and Srivastava 1968
D_MS      =[96 120.86 152.15 191.55 241.14 303.58 382.18 481.14 605.72];
w_max_MS  =[23.4 28.8 35.0 42.2 50.5 60.0 71.3 83.9 98.5];
phi_max_MS=[0.95 1.36 1.85 2.42 3.08 3.83 4.69 5.71 6.81];
%Collins and Dennis 1975
D_CD      =[96 500 605.72 1000 2000 3500 5000];
w_max_CD  =[23.35 83.69 96.53 141.3 236.5 351.4 449.3];
phi_max_CD=[0.990 6.116 6.911 9.208 13.19 17.13 19.97];
flux_CD   =1./[1.023 1.337 1.389 1.550 1.852 2.165 2.392];
w_pos_CD  =[0.31 0.56 0.64 0.71 0.76 0.78];
D_CD_mod  =[96 500 1000 2000 3500 5000];

D=[10 100 250 500 1000 2000 5000]
D_ret=0.0*D;

QR_ret_o=D_ret;
maxW_ret_o=D_ret;
r_maxW_ret_o=D_ret;
%
maxPhi_ret_o=D_ret;
max_phi_ret_u=D_ret;

QR_ret_u=D_ret;
maxW_ret_u=D_ret;
r_maxW_ret_u=D_ret;

for i=1:length(D)

[D_ret_o(i),QR_ret_o(i),maxW_ret_o(i),r_maxW_ret_o(i),maxPhi_ret_o(i)] = phi_original_D_loop_QR_Wmax (D(i));
[D_ret_u(i),QR_ret_u(i),maxW_ret_u(i),r_maxW_ret_u(i),maxPhi_ret_u(i)] = phi_updated_D_loop_QR_Wmax (D(i));

endfor

f1=figure(1)
plot(D,QR_ret_o,'-ob')
hold on
plot(D,QR_ret_u,':sr')
%CD
plot(D_CD,flux_CD,'--^m')
grid on
xlabel('D')
ylabel('Flux')
ylim([0 1])
legend('Original','Updated','Collins and Dennis 1975')
saveas (f1, 'flux.png');
%print -color -depsc QR.eps

f2=figure(2)
plot(D,maxW_ret_o,'-ob')
hold on
plot(D,maxW_ret_u,':sr')
%MS
plot(D_MS,w_max_MS,'-.dk')
%CD
plot(D_CD,w_max_CD,'--^m')
grid on
xlabel('D')
ylabel('w_{max}')
legend('Original','Updated','McConalogue and Srivastava 1968','Collins and Dennis 1975','location','northwest','fontsize',10)
saveas (f2, 'w_max.png');
%print -color -depsc Wmax.eps

f3=figure(3)
plot(D,r_maxW_ret_o,'-ob')
hold on
plot(D,r_maxW_ret_u,':sr')
%CD
plot(D_CD_mod,w_pos_CD,'--^m')
grid on
xlabel('D')
ylabel('r_{w_{max}}')
ylim([0 1])
legend('Original','Updated','Collins and Dennis 1975 (estimated)','location','southeast')
saveas (f3, 'r_w_max.png');
%print -color -depsc r_Wmax.eps

f4=figure(4)
plot(D,maxPhi_ret_o,'-ob')
hold on
plot(D,maxPhi_ret_u,':sr')
%MS
plot(D_MS,phi_max_MS,'-.dk')
%CD
plot(D_CD,phi_max_CD,'--^m')
grid on
xlabel('D')
ylabel('\Phi_{max}')
legend('Original','Updated','McConalogue and Srivastava 1968','Collins and Dennis 1975','location','southeast','fontsize',10)
saveas (f4, 'phi_max.png');
%print -color -depsc Wmax.eps

