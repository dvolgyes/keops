addpath build

Nx = 500;
Ny = 200;
x = randn(3,Nx);
y = randn(3,Ny);
b = randn(3,Ny);
p = .25;

F = Kernel('Vx(0,3)','Vy(1,3)','GaussKernel_(3,3)');
g = F(x,y,b,p);

ox = ones(Nx,1);
oy = ones(Ny,1);
r2=0;
for k=1:3
    xmy = ox*y(k,:)-(oy*x(k,:))';
    r2 = r2 + xmy.^2;
end
g0 = (exp(-p*r2)*b')';

norm(g-g0)
